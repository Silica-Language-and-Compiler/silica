# Chunk 15 detailed design: the stack-based memory model

**Date:** 2026-10-24
**Status:** design, pre-implementation. Written by Fable at Lee's request. Nothing in this document is implemented; every statement about the code as it is today is marked **today:** or carries a `file:line` reference that was read for this document.
**Authority:** [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) §2A decisions 1 to 40 (binding, Lee 2026-10-24) and §7.5 (the twelve groups this document must settle). Where this document and the requirements differ, the requirements win. [region_memory_safety_design.md](region_memory_safety_design.md) §10, §13, §14, §18 and §19 are the design record this document continues; [actor_growable_stack_design.md](actor_growable_stack_design.md), [Phase1_TODOs/actor_stack_growth_plan.md](Phase1_TODOs/actor_stack_growth_plan.md) and [actor_memory_budget_plan.md](actor_memory_budget_plan.md) describe the stacks this design builds on.
**Rules this document follows.** Decisions 1 to 40 are not reopened. Where the decisions leave a choice (an offset, an algorithm, a spelling, a code number) this document chooses, says why, and marks the choice **proposal — Lee to confirm** when it is user-visible (syntax, error codes, spellings) or changes behaviour. Where a decision cannot be implemented as stated, or two decisions meet, §13 says so plainly. Reclamation is deterministic everywhere: there is no threshold, no sweep and nothing done "every so often" (decision 4); every cost below is stated in operations proportional to a quantity the program controls.

## Contents

0. Summary and the model in one page
1. Today, measured (what the design replaces)
2. Memory layout per actor (hosted and ESP32-S3)
3. Code generation: frames, allocation, returns
4. Dispatch end: compiler-proven release, the fallback, evacuation into the state area
5. Messages, replies and spawn
6. The lifetime-only region checker
7. FFI buffers and declared retention
8. Standard library: field removal, frame allocation, result reshaping, persistence
9. Removal of the implicit heap and the family arenas (site by site)
10. Error handling: failure reasons by cause (decision 39; was `(:explicit, :stack_exhausted)`)
11. Implementation plan, trials, specification changes, risks and costs
12. Proposals for Lee (collected)
13. Problems found

## 0. Summary and the model in one page

An actor owns one stack. Everything the actor computes lives in that stack:

- **Frames** hold working values and every value that may escape: structure nodes, list cells, strings, records and tuples. A frame has a fixed part (X29 slots, as today) and a dynamic part grown by moving SP. Nothing in a frame is freed individually; the frame's pop frees all of it (Lee's cleanup-on-pop rule).
- A **returned** value is delivered by destination-passing where the compiler sees the flow (a static-size result in the caller's X8 slot, as since 2026-10-12; a variable-size result built in a frame the caller **adopts**, §3.3) and otherwise **evacuated**: the nodes of the result that lie in the popped frame are copied up into the caller's frame, forwarding pointers written into the dead frame keep sharing, older nodes are left where they are.
- The **state area** sits at the base of the stack and grows downward only at dispatch end (decisions 3, 14). At dispatch end the new state's nodes that lie in frames or in the message buffer are evacuated into it (two copies of the new nodes on hosted targets via scratch below the dispatch's deepest point, one copy on the ESP32-S3, §4.3). Dead nodes of the old state are released by **compiler-proven release**: a per-behaviour analysis (§4.1) proves that each state lineage was updated along one chain whose end is kept; then each update's `retire` of the nodes it replaced is honoured from a per-dispatch log, freed into exact-size free lists at dispatch end (decisions 18, 21). Where the proof fails, the compiler says so (W2300, or E2321 in strict mode; §4.5) and every dispatch end copies the whole live state (decisions 19, 28).
- A **message** is copied by the sender into a buffer attached to the mailbox node and released at dispatch end unless forwarded whole (decisions 7, 30, 31, 32, 38). A **reply** is copied straight into the blocked caller's stack below its parked SP (decision 33). A **spawn** or **restart** copies the initial state into the child's state area before its first dispatch (decisions 11, 15).
- `region(L, S)` is a lifetime witness over the frame that created it; `alloc_*` into any region allocates in the current frame (decisions 12, 34). The **region checker** (§6) enforces lifetimes only: use after an explicit `move` (E2301), a reference written where it would outlive its frame (E2302), isolation and polymorphism (E2310, E2311), retention across the FFI boundary (E2300), and `device_window`'s single owner (E2242, proposal).
- The **implicit heap**, the **family arenas**, the string arena and the dispatch-end region heuristics are removed (§9). What stays outside the stack is listed in §2.7: mailbox buffers, call records, the release log, the FFI arena, atomic regions, device windows, and the runtime's own tables.

**Reading order.** §2 and §3 are the mechanics every later section assumes; §4 is the hardest part (release); §11 is the plan and §13 lists what Lee must look at before implementation starts.
## 1. Today, measured (what the design replaces)

Read for this document on 2026-10-24 (apple_silicon_mac unless stated; the Linux twins mirror it, the ESP32-S3 differs where said).

| Fact | Where |
| --- | --- |
| Working values are in fixed X29 frames; aggregate "regions" are node-indexed frame slots (`frame_region_for`, `next_frame_region`) | `terms/term_reg_spill.silica:1103-1131` |
| Escaping aggregates are copied to the implicit heap by `aggregate_return_heap_promote_x0_copy` (`BL _silica_rt_region_alloc`), `arg_aggregate_heap_promote`, `tuple_elem_heap_promote`, `frame_var_arg_promote`, `tuple_elem_frame_var_promote` | `terms/term_aggregate_helpers.silica:538-620, 689-706` |
| Static-size results go to a caller slot in X8 (`sret_save_x8`, `sret_tuple_epilogue_copy`, `user_call_aggregate_return_alloc_bytes`) | `emitter_core.silica:3270-3285`, `terms/term_user_call_abi.silica:113-134` |
| The implicit heap: a per-actor chain of 64 MB `mmap` blocks, bump pointer at ACB #176, limit #184, newest block #160, bytes mapped #168; freed only by `_silica_rt_actor_dealloc_region` at actor end; `main` falls back to a global malloc list that is never freed | `terms/prims/prims_actors_runtime_asm.silica:3440-3504, 3669-3760` |
| List handles (24 B) and chunks (`CDATA+16`) are heap-allocated by `L_list_prepend_helper` (three `_silica_rt_region_alloc` sites) and `emit_list_head_box` | `terms/prims/prims_list.silica:21-32, 442-453, 606-700` |
| Strings concatenate into a process-wide 4 MB-chunk bump arena under a spinlock (`L_sc_bump_alloc`), never freed except by the disabled mark/release | `terms/string_concat_mmap_nomte.silica:48-76` |
| Region prims bump a 4128-byte block chain with LDAXR/STXR (`emit_region_bump_check`), `alloc_region` is `_silica_rt_raw_alloc(4128)` | `terms/prims/prims_memory.silica:137-185` |
| Standard structures allocate from one process-global never-freed arena per family (`_silica_rt_canonical_arena_lookup`, 512-slot table, insert under `_silica_rt_region_lock`) | `terms/canonical_arena_runtime_asm.silica:17-60`; 11 stdlib constructor sites, §8.1 |
| Actor state is a pointer at ACB #0 into the actor's own heap; the behaviour epilogue copies the new state shell there (`bmv_state_asm`) or overwrites a tagged block in place (`bmv_state_reuse_asm`, tag `ACB ^ 0x5C1A57E0...`) | `terms/prims/prims_actors.silica:594-656`; dispatch store `str x9,[x19]` at `prims_actors_runtime_asm.silica:870` |
| A reply is copied into the **caller's** arena (`_silica_rt_region_alloc_in`, caller ACB at wrapper +56; H4 fix) or deep-copied by the message copier into a fresh region | `prims_actors.silica:556-592`, `term_message_copy.silica:844-858` |
| Messages: a 152-byte calloc'd node per message (+8 payload, +16 needs_reply, +24 ingress kind / futex, +32 owned payload kind; a call node is also the call wrapper: +48 parked actor, +56 caller ACB, +72 lock, +136 reply_set, +144 reply); the payload is copied into the **sender's** arena by the type-directed copier and never freed; the node is freed after dispatch | `prims_actors_runtime_asm.silica:1131-1255, 1396-1520, 923-949` |
| The copier: descriptors KIND 0 to 6, `L_mc_root`, per-message open-addressing table, pre-map of region words to fresh 4128-byte regions, KIND 0 for lists and unbound `rec` refs (shared with the sender), `fn_copy_markers` last-use elision `\|_mvs=` and `\|_mvr=1` | `terms/term_message_copy.silica:18-74, 820-858, 899-982` |
| Dispatch-scoped release of a message record's region fields at behaviour return when a taint proof holds | `terms/term_message_regions.silica:18-54` |
| `call`: the caller enqueues the wrapper, then parks: a carrier actor saves its context below SP (`_silica_rt_ctx_save`, SP recorded at ACB #464, status #448 = 4) and enters the carrier loop; a dangerous actor or `main` futex-waits on wrapper +24 under lock +72; the replier stores the reply at +144, `reply_set` at +136 and wakes (`_silica_rt_call_wrapper_wake`) | `prims_actors_runtime_asm.silica:1396-1520, 887-921`; `prims_actors_carrier_asm.silica:1077-1103, 1923-1943` |
| Spawn stores the initial-state pointer verbatim (`stp x21,x20,[x19]`); the **spawner's** emitted code copied it into the spawner's arena first (`spawn_init_move_asm`); a child row stores the spec's init pointer and every restart re-passes the same pointer | `prims_actors_runtime_asm.silica:111-151`, `prims_actors.silica:432-460`, `prims_actors_child_table_asm.silica:29-30, 428-438, 581, 715` |
| Stacks: one reservation per actor (ACB #272 base, #280 bytes, #288 committed, #296 high water, #304 next chunk, #312 algorithm, #320 retained, #328 ring, #336 ring index, #344 last time, #352 alt stack, #360 policy, #368 saved SP, #376 lowered, #384 reason); release at the boundary by `_silica_rt_stack_on_message_return`, measured by `_silica_rt_stack_measure` (lowest nonzero word from the committed run upward), released by `_silica_rt_stack_release_to` (MAP_FIXED remap, then zero the used range) | `terms/prims/prims_actors_stack_asm.silica:30-42, 357-455, 602-762` |
| ACB is 528 B; #0 state, #8 behaviour, #16 lock, #80 mailbox futex, #128/#136 mailbox, #152 alive, #160..#184 arena, #216 SB, #240 active call wrapper, #248/#256/#264 FFI arena, #392..#520 holders, identity, carrier fields, parked SP #464, thread record, migration, priority | `prims_actors_runtime_asm.silica:29-59` |
| Actor end: registry forget, exit delivery, `_silica_rt_actor_signal_pending_call_deaths` (walks the pending mailbox, frees nodes, signals callers, frees nothing of the payloads), child table free, stack free, FFI arena teardown, arena dealloc, final release | `prims_actors_runtime_asm.silica:958-1010, 1286-1352` |
| **ESP32-S3:** ACB 144 B (`ACB_STATE` 0 inline slot with `ACB_STATE_OWNED` byte 23; machine chain `ACB_MCHAIN`/`ACB_MCUR` 44/48, auxiliary 52/56; policy 88; peak 116; high water 120/124); stacks are chains of heap chunks (header 64 B: next, prev, size, ret, limit, top, band, index, mirror; usable from +128; first 2048 / 512 B, cap 16 KB / 4 KB), grown by the emitted prologue check against `VRG_MLIMIT` and `silica_rt_stack_grow`, trimmed at the boundary by `silica_rt_actor_release_policy`; the heap is first-fit over an address-sorted free list under a spinlock, `silica_rt_region_alloc` is an alias of `silica_rt_alloc`; state is a heap block replaced per dispatch by `silica_rt_state_release`, which keeps the old block if `silica_rt_heap_reaches(new, old)` finds it within depth 4; a message node is 48 B; a `call` parks the caller mid-behaviour with its chunks live and the reply is written into the node | `board/runtime/rt_actors.S:99-207, 309-345, 986-1035, 1109-1144, 1462-1514, 1657-1750, 1911-2118, 2458-2680, 3694-3945`; `rt_heap.S:63-80, 90-370, 473-520`; `rt_supervisors.S:101-117, 408-505` |
| SIR: kinds 0 const, 1 var, 2 let, 3 case, 4 call, 5 tail_call, 6 prim, 7 case_branch_seq, 8 case_branch; metadata rides in the node's `value` string (`\|mv` from `tag_mv`) and the effects string (`\|sir_rec:`); a region checker would be inserted in `main_compile_pipeline.silica` between the effect check (:257) and SIR generation (:268), on the `ffi_taint_checker` model (:247) | `src/sir_generator/sir_ast.silica:58-59`, `terms/terms_actor_lowering.silica:474-492`, `src/main_compile_pipeline.silica:247-268` |
| Diagnostics: `print_compiler_error` and `print_compiler_warning` (W2201, W4001 exist); `silica.config` is a file list (lines starting `#` skipped) with no keys; the compiler reads no environment variables | `src/diagnostics/diagnostics_core.silica:89, 138`; `src/main_lists.silica:132-152` |
| Codes: E2300 to E2312 unregistered; E2313/E2314 registered; E2311 does not exist in `src`; highest device code E2241; E2319/E2320 retired and not reused | `compiler/error_codes.md:73-144, 201-203` |
| Lifetime analysis is Phase A only; `type_checker_memory_regions.silica:585` still emits E2100 for "reference outlives region"; per-call lifetime substitution (Q10) does not exist | `src/type_checker/type_checker_memory_regions.silica:573-601`, `expressions/type_checker_expressions_identifiers.silica:1014-1038` |
## 2. Memory layout per actor

### 2.1 The hosted reservation

```
 top = base + reservation            +------------------------------+
                                     | state-area header   1,040 B  |  129 free-list heads (§2.3), zero = empty
 top - 1040                          +------------------------------+
                                     | state area                   |  nodes of the live state, exact-size holes
                                     |   grows down at dispatch end |  never decommitted while the actor lives
 edge  (ACB #528)                --> +------------------------------+  moves down at dispatch end only
                                     | dispatch frame (48 B today)  |  the runtime's frame for the behaviour call
                                     | behaviour frame              |  fixed part, then dynamic part (§3.1)
                                     | callee frames ...            |  each fixed + dynamic, growing down
 SP                              --> +------------------------------+
                                     | (dead frames of this         |  readable: the scratch of §3.5 / §4.3
                                     |  dispatch's deeper calls)    |  starts at the committed run's bottom
 top - committed  (ACB #288)     --> +------------------------------+  the committed run [top-committed, top)
                                     | inaccessible remainder       |  grown by the fault handler (unchanged)
 base (ACB #272)                     +------------------------------+  lowest page never committed (unchanged)
```

Nothing changes in how the reservation is made, grown or freed (`_silica_rt_actor_stack_reserve` 357-455, `_silica_rt_stack_grow_to` 530-599, `_silica_rt_actor_stack_free` 494). What changes is that the top of the committed run is no longer empty between messages: it holds the state area, and the release algorithms measure from the edge (§2.4).

### 2.2 New control-block words

**Hosted (proposal, not user-visible): the ACB grows from 528 to 592 bytes**, new fields at #528..#591. The survey of #0..#215 found two ranges with no store or load (#24..#71, #88..#127) but could not confirm them free; the block has grown four times already (`prims_actors_runtime_asm.silica:29-32`: 512, +16, +32, +16, +16, +16) and extending it is the safe choice. Every `calloc(1, 528)`, the static `_silica_rt_dead_acb` (`.space 392` plus constants, RT:6636) and the x86 twin's `528` change together.

| Offset | Word | Meaning |
| --- | --- | --- |
| #528 | **state edge** | address of the lowest byte of the state area; `top - 1040` for an actor with no state yet. The release algorithms, the evacuation routine's "old node" test and the stack measurer read it (decision 27). |
| #536 | release log base | address of the per-actor release log (§4.2), a `malloc`'d array of 16-byte entries `(node, size)`; 0 until the first logged retire |
| #544 | release log count | entries used this dispatch; reset to 0 at dispatch start |
| #552 | release log capacity | entries allocated; doubled by `realloc` when full (the only growth, O(1) amortised, proportional to retired nodes) |
| #560 | release enabled | 1 while a dispatch of a **proven** behaviour runs (stored by the behaviour's prologue, §4.1), else 0; `retire` tests it |
| #568 | state bytes live | bytes of live nodes in the state area (allocated minus freed), kept for `get_actor_memory_usage` and the fallback's sizing (§4.4) |
| #576 | **state policy** (decision 40) | the spawn's `state_policy` choice: 0 `:keep_state_area`, 1 `:shrink_after_compaction`, 2 `:compact_on_request`; stored at spawn before the first dispatch (§5.4), never changed |
| #584 | compaction requested | set to 1 by `compact_state()` during a dispatch, tested and cleared at dispatch end (§4.7) |
| #592 and up | (none) | the ACB stays 592 B (P12): the two words above use the words that were reserved as `#576..#591`, so the next growth must add words |

**ESP32-S3 (proposal, not user-visible): the ACB grows from 144 to 160 bytes** (`rt_actors.S:154-199`, `ACB_SIZE`):

| Offset | Field | Meaning |
| --- | --- | --- |
| 144 | `ACB_SCHAIN` | first chunk of the **state chain** (§2.6); 0 none |
| 148 | `ACB_SCUR` | the state chunk being filled (its header holds the bump) |
| 152 | `ACB_SLOG` | the release log block (heap; `[0]` count, `[4]` capacity, entries of two 4-byte words from +8) |
| 156 | `ACB_SFLAGS` | byte 156: release enabled; byte 157: **state policy** (decision 40, same codes 0 to 2); byte 158: compaction requested; byte 159 free |

1,000 actors cost 16 KB more ACB on the board (budget plan §7.1; §11.5 records it).

### 2.3 The state area and its free lists (decision 21)

The state area holds **nodes**: records (shape word + one word per field), `alloc_rec` cells with their payloads, `alloc_ref` cells, buffers, list handles and chunks, strings, closure environments, in the layouts of §3.6. Every node has an exact size, a multiple of 8, known from its descriptor, so no node carries a header. Nodes never move once placed (decision 21), so a pointer into the state area is stable for the actor's life unless the node is freed.

**Free lists.** The header at `[top-1040, top)` holds 129 list heads: head `i` (`i = 0..127`) for nodes of size `8*(i+1)` bytes, that is 8 to 1,024 bytes, and head 128 for every size above 1,024. A freed node's first word becomes the list link; a free node of size above 1,024 keeps its size in its second word. Allocation of `n` bytes: `n <= 1024`: pop head `n/8 - 1` if non-empty (O(1)); `n > 1024`: walk head 128 for an exact size (O(number of large free nodes), deterministic and bounded by the number of large nodes the behaviour has retired and not reused; the fallback compaction empties it, decision 21); otherwise **extend the edge**: `edge -= n`, the node is `[edge, edge+n)`. Free: push on the list for the size (O(1)). The header is zero when the page is first committed (fresh pages are zero, `prims_actors_stack_asm.silica:45-48`), so an empty table needs no initialisation.

Why exact size rather than size classes: decision 21 chose exact-size lists so that a released node is reused only by a node of the same size and live nodes never move; a size-class allocator would either split (then nodes of odd sizes drift) or round up (then the log's sizes and the descriptors' sizes disagree). The waste is holes of sizes no longer used, which only the fallback copy compacts (decision 21); §4.4 says when that happens and §11.5 what it costs.

### 2.4 The `stack_policy` algorithms measure from the edge (decision 27)

`_silica_rt_stack_on_message_return` (`prims_actors_stack_asm.silica:696-762`) and its two helpers change as follows; the five algorithms keep their meaning.

| Routine | Today | Under the design |
| --- | --- | --- |
| `_silica_rt_stack_measure` (602-630) | scans from `top - committed` up to `top`, returns bytes from `top` down to the lowest nonzero word | scans up to **edge** (`[acb, #528]`) and returns bytes from the edge down; the state area is never scanned |
| `_silica_rt_stack_release_to` (633-693): keep X1 bytes, zero X2 bytes | `prefix_for(X1)` from the top; `mmap MAP_FIXED` below `top - prefix`; `memset(top - X2, 0, X2)` | the kept prefix is `(top - edge) + prefix_for(X1)` so the state area is always inside the committed run; the zeroing range is `[edge - X2, edge)` and never touches `[edge, top)` |
| `Lsmr_release_all` (`:release_on_return`) | keep 0 | keep 0 below the edge: the committed run shrinks to `[edge, top)` rounded up to the chunk the fault handler would next grow by; **the state area is never decommitted while the actor lives** (decision 27) **[amended 2026-10-24, decision 40: this holds only under `:keep_state_area`; under `:shrink_after_compaction` and `:compact_on_request` the edge moves up and the pages above the compacted end are decommitted at dispatch end, §4.7]** |
| `Lsmr_keep_all` (`:keep_high_water`), `Lsmr_idle_stamp` (`:release_when_idle`) | record committed as retained | unchanged in shape; the idle sweep (`_silica_rt_carrier_sweep`, `_silica_rt_stack_idle_check`) releases down to `[edge, top)`, not to nothing |
| `:keep_last_message`, `:track_recent_peak` | ring of measured depths from the top | depths measured from the edge; the ring entries are therefore comparable across dispatches even as the edge moves |
| `_silica_rt_get_actor_memory_usage_acb` (1078) | reserved, committed, retained, high-water | unchanged fields (spec §22.4 fixes four); `committed` and `high_water` include the state area, `retained` is what the algorithm keeps **below** the edge; `#568` (state bytes live) is available for a future field but no field is added (spec change otherwise) |
| `_silica_rt_actor_stack_free` (494) | unmaps the reservation | unchanged: the state area dies with the stack (decision 16: an actor's end releases everything) |

The edge moves only in the dispatch-end routine (§4.3, §4.4), which runs **before** `_silica_rt_stack_on_message_return` (today's order at `prims_actors_runtime_asm.silica:858-870` is release algorithm then state store; the design runs evacuation, then the release algorithm, then the reply handoff, §4.6).

### 2.5 Scratch below the deepest point (decisions 20, 28)

Hosted targets do not track the deepest SP of a dispatch (no per-call check exists; the fault handler grows pages). The scratch of §3.5 and §4.3 therefore starts at the **bottom of the committed run** (`top - [acb, #288]`), which is at or below every frame the dispatch pushed, and grows downward. Writing below the committed run faults and grows it by the ordinary path, so the scratch costs its own page commits (one fault per 16 KB page on Apple silicon; the first chunk sizes have long passed their doubling, so each fault commits 1 MB, `_silica_rt_stack_grow_to` 575-581) and those pages are then subject to the release algorithm like any other. For a **frame return** (§3.5) the scratch is simply below the callee's SP: every deeper frame has returned, so `[.., SP)` is dead and no bound needs reading. A lowered reservation that cannot hold the scratch ends the actor with `(:explicit, :stack_exhausted)` (§10) [2026-10-24, decision 39: `:reservation_exceeded`].

### 2.6 ESP32-S3: chunk chains, the state chain and what "base", "edge" and "scratch" mean there

The board's stacks are chains of heap chunks taken at dispatch and trimmed at the boundary (`silica_rt_alloc_stack` 1109-1144, `silica_rt_chunk_take` 1482-1514, `silica_rt_actor_release_policy` 2043-2118). There is no contiguous base, so the state area is a **third chain**: the state chain, `ACB_SCHAIN`/`ACB_SCUR`, of heap chunks with the same 64-byte header family (`CH_NEXT`, `CH_PREV`, `CH_SIZE`, `CH_TOP`; `CH_LIMIT` reused as the chunk's bump, `CH_RET` unused), filled **upward** from +64 by a bump, with the 129 free-list heads in the first chunk's data (516 bytes of 4-byte heads). The mapping of the hosted words:

| Hosted | Board |
| --- | --- |
| the state area `[edge, top)` | the state chain's chunks; "in the state area" = `silica_rt_chain_contains(ACB_SCHAIN, p)`, a walk over the chain's chunks (O(chunks), a handful), used by `retire` and the evacuation's old-node test; the free lists make the walk rarer than the hosted compare but it is on the per-node path of evacuation, so the state chunks are kept few: first chunk 2,048 B, doubling to a 16 KB cap like the machine chain |
| the edge | the bump of `ACB_SCUR`; "extending the edge" = bump, or `silica_rt_chunk_take` of a new state chunk when the bump cannot fit (a node never spans chunks) |
| scratch below the deepest point | **not needed for a dispatch end**: the destination (state chain) and the sources (machine chunks, message payload blocks) are disjoint heap blocks, so the evacuation copies in **one pass** straight to final addresses. For a frame return (§3.5) the destination is the caller's dynamic part; if the callee's frame is in the **same** machine chunk as the caller's SP the destination overlaps the sources and a transient heap block (`silica_rt_alloc_or_null`, freed after pass 2) is the scratch; if the callee's frame is in a later chunk the copy is direct. The choice is made at run time from the chunk index (`CH_INDEX`), not by the compiler; it changes the cost, never the result |
| `stack_policy` measuring from the edge | nothing to change: the policies trim the machine and auxiliary chains (2059-2111) and never touch the state chain; `ACB_PEAK`'s chunk indices stay as they are |
| sizing against the reservation (decision 26) | `silica_rt_chunk_next`'s lowered-reserve test (1584-1643, the −1 return) counts `chain_bytes(MCHAIN) + chain_bytes(ACHAIN) + chain_bytes(SCHAIN)`; heap exhaustion by state growth under the default reserve is the board's runtime abort 71 as for stacks (spec §15.1.2.2 implementation note) |
| actor end | `silica_rt_actor_recycle_stacks` (2417-2432) returns the state chain to the heap with the other two; `silica_rt_state_release` and `ACB_STATE_OWNED` are **removed** (§9.3): the state is nodes in the state chain and `ACB_STATE` points at its root |
| `get_actor_memory_usage` (6157-6199) | `committed` and `high_water` include the state chain's bytes; `retained` excludes it |

**Why the state is not kept in the machine chain's first chunk.** The first machine chunk is released by `:release_on_return` and reused from the stack free list by other actors (`silica_rt_stack_free`, 1163; exact-size reuse at 1109-1144); keeping state there would make it unreleasable and would pin a 2 KB chunk per idle actor, against item F's purpose. A separate chain costs one 64-byte header per state chunk and lets an idle actor's state be exactly its size.

### 2.7 What stays outside the stack

Decision 2 removes the implicit heap and decision 1 the family arenas. The following memory stays outside every actor's stack, each with its owner and release, so that "nothing goes to a heap" is read precisely:

| Memory | Owner | Released |
| --- | --- | --- |
| mailbox nodes (152 B hosted, 48 B board) and the **mailbox buffer** holding a message copy (§5.1) | the receiving actor's mailbox | node after dispatch (today); buffer at dispatch end unless forwarded (decision 7), or by the end-of-actor drain (decision 31) |
| the call record (the call node, §5.3) | the caller | by the last of caller and replier to touch it under its lock (§5.3) |
| the release log (§2.2) | the actor | at actor end with the ACB |
| child-table rows and the **row spec buffer** holding a child spec's initial state (§5.4) | the supervisor's child table | when the row is removed or the supervisor ends |
| the FFI arena (ACB #248..#264) | a dangerous actor | at its end (`_silica_rt_ffi_arena_teardown`, unchanged) |
| `region(L, atomic)` shared cells (Q7) and `device_window` (decisions 8, 24) | as today | as today |
| string literals, descriptors, atom tables | the executable | never |
| the runtime's own tables (registry, identity table, timers, carriers) | the process | as today |

None of these is reachable from user code as "memory" except through the typed values the runtime hands out, and none grows without a matching release path.
## 3. Code generation: frames, allocation, returns

This section replaces the implicit heap in the emitted code. It covers §7.5 items 3, 4 and 8.

### 3.1 Two parts of every frame

Today a function's frame is fixed at compile time: locals, spills and aggregate "regions" are X29-relative slots sized by `term_reg_spill@frame_region_for` / `next_frame_region` (memory note "Aggregates in frame regions"), and the only SP movement inside a body is the balanced `SUB SP` / `ADD SP` pair around an sret call or a tuple argument slab (`term_aggregate_helpers@let_user_call_tuple_sret_stack_bytes`, `call_tuple_args_dealloc_bytes`). Everything that must outlive the frame is copied to the implicit heap by one of the promote helpers (`aggregate_return_heap_promote_x0_copy`, term_aggregate_helpers.silica:689-706, which calls `_silica_rt_region_alloc`; `arg_aggregate_heap_promote` 551; `tuple_elem_heap_promote` 565; `frame_var_arg_promote` 606; `emit_list_head_box`, prims_list.silica:442-453; `L_list_prepend_helper`'s three `_silica_rt_region_alloc` calls, prims_list.silica:659-690; `L_concat_helper`'s bump arena, string_concat_mmap_nomte.silica:48-56).

Under the design a frame has two parts:

| Part | Addressed | Holds | Released |
| --- | --- | --- | --- |
| **Fixed part** | `[X29, #-N]` slots, as today | saved registers, spills, let homes, fixed-size aggregate regions, the sret slot | at the epilogue (`MOV SP, X29`-style restore, as today) |
| **Dynamic part** | below the fixed part, grown by `SUB SP, SP, #n` and addressed through the pointer the allocation returns | every value that may escape: structure nodes (`alloc_rec`, `alloc_ref`, `alloc_buf`), list handles and chunks, run-time strings, records and tuples that today are promoted, `alloc_region` areas | at the epilogue with the fixed part (SP is restored from X29), or earlier when the frame is adopted (§3.4) |

The dynamic part is a bump allocator whose cursor is SP. One allocation is `SUB SP, SP, #n16` (n rounded up to 16, the AArch64 SP alignment; on x86-64 `sub rsp, n16`) and the node's address is the new SP. There is no header, no free list and no size word in the frame: a frame node's size is known statically wherever it is used (its type), and the whole dynamic part vanishes when the frame pops. Nothing in a frame is ever freed individually; that is Lee's cleanup-on-pop rule (requirements R4.3, design §19.2) and it is what makes release in a frame cost nothing.

**Why SP and not a second cursor register.** A second bump register would cost a callee-saved register in every function that allocates, and every call would have to save and restore it. SP already is a cursor, the fault handler already grows the stack under it, and the epilogue already restores it. The emitter's fixed-frame discipline (locals off X29, memory notes "Fixed frames: short circuit" and "Aggregates in frame regions") is exactly what makes SP movement inside a body safe: a `SUB SP` for a node never changes the address of any X29-relative slot. The two places that are SP-relative today, the sret slab and the tuple argument slab, stay balanced within their own `SUB`/`ADD` pair and are allocated below whatever nodes the body has already pushed; `tuple_flat_memref` renders `[SP, #off]` only for a store base that is empty (term_aggregate_helpers.silica:135-151), which is the slab just pushed, so its offsets stay right.

**Alignment.** Frame nodes are 16-byte aligned (SP). State-area nodes (§4) are 8-byte aligned and exactly sized; the descriptor of a node (§3.6) gives its exact size, so an evacuated node takes exactly its 8-byte-rounded size in the state area regardless of its 16-byte frame footprint.

### 3.2 The frame allocation prims (replacing `_silica_rt_region_alloc`)

Every emitted `BL _silica_rt_region_alloc` (requirements §8.2) becomes an inline frame allocation. One emitter helper per target produces it; it takes the byte count in a register or an immediate and leaves the address in the destination register:

| Target | Sequence | Notes |
| --- | --- | --- |
| apple_silicon_mac, linux_aarch64 | `ADD X16, Xn, #15 ; AND X16, X16, #~15 ; SUB SP, SP, X16 ; MOV Xd, SP` (immediate form: `SUB SP, SP, #n16 ; MOV Xd, SP`) | X16/X17 are the emitter's scratch (IP0/IP1); an immediate above 4095 goes through `var@mov_imm_wide` as `emit_sub_from_fp` does (term_aggregate_helpers.silica:98-103) |
| linux_x86_64 | `lea r11, [rax+15] ; and r11, -16 ; sub rsp, r11 ; mov rd, rsp` | r11 is the scratch of the x86 ISA helpers; the SysV red zone is not used by emitted code |
| ESP32-S3_raw | `movi/addi a8, n16 ; sub a8, a1, a8 ; movsp a1, a8 ; mov ad, a1` preceded by the chunk limit check | the limit check is the one `function_prologue` emits (control/control.silica:51-54): `l32i a8, threadptr+116 (VRG_MLIMIT); bgeu a1, a8` and a call to `silica_rt_stack_grow` when the new SP would cross it; a frame never spans chunks, so a dynamic allocation that does not fit the current chunk moves the **allocation** to a new chunk, not the frame: the helper returns a pointer into the new chunk and SP stays, see §2.6 |

A dynamic allocation can fault on hosted targets (the first touch of a new page): that fault is stack growth exactly as for a frame (`_silica_rt_stack_grow_to`, prims_actors_stack_asm.silica:530-599). The lowest page rule (the reservation's last page is never committed, 550-558) gives `(:explicit, :stack_exhausted)` for a lowered reservation (§10) [2026-10-24, decision 39: `:reservation_exceeded`].

**The language-level prims** (`alloc_ref`, `alloc_rec`, `alloc_buf`, `alloc_region`) are emitted by prims_memory.silica today through `emit_region_bump_check` (181-185; the LDAXR/STXR bump over a region block). They become frame allocations:

| Prim | Today | Under the design |
| --- | --- | --- |
| `alloc_region(space)` (137-157) | `_silica_rt_raw_alloc(4128)`, a block header `[bump, end, chain, span]` | returns a **lifetime witness**: the word `X29` of the allocating frame (a frame-unique value that is never dereferenced; §6 explains what the checker does with the lifetime). No memory is allocated for the region itself; its "area" is the dynamic part of the frame that allocates into it. Decision 34 (`alloc_region` allocates an area in the current frame) is met: the area is the frame's dynamic part, bounded by the frame's life. |
| `alloc_ref(r, scalar)` (210-218) | bump 8 bytes in `r` | frame allocation of 16 bytes (one word used); the handle `r` is not read |
| `alloc_ref(r, tuple)` / `alloc_rec(r, tuple)` (223-232 and `emit_alloc_rec`) | cell word + payload copy in `r` | one frame allocation of `8 + words*8` rounded to 16: the cell word at +0 pointing at the payload at +8, the layout `L_mc_refrec` already produces for copies (term_message_copy.silica:967), so REFTUP descriptors keep working |
| `alloc_buf(r, n)` (302) | length word + elements in `r` | frame allocation of `8 + n*elem` rounded to 16, length word at +0, elements from +8, exactly today's layout so `emit_buf_bounds_check` (345) is unchanged |
| region-less forms **(proposal — Lee to confirm, user-visible)**: `alloc_ref(v)`, `alloc_rec(v)`, `alloc_buf(n)` | do not exist | the same allocations; the lifetime and the memory space come from the **binding's annotation**, which the specification already uses for `alloc_region` ("the lifetime identifier Lᵢ is taken from the explicit type annotation on the binding", spec §12.1.4). The stdlib, which carries no region field after decision 13, uses these forms (§8). The effect `mem(Space)` is taken from the annotation's space exactly as `effect_checker_memory_regions@get_region_call_effects` takes it from the region argument today. |
| `read_ref`, `write_ref`, `buf_load`, `buf_store`, `ref_eq` | unchanged | unchanged; `write_ref` gets the checker rule of §6.3 |
| `ref_in_region(ref, r)` (113-115) | walks the region's block chain | **retired** (proposal — Lee to confirm): with a region a lifetime witness there is no range to test; the one stdlib use (wbt_map.silica:7953, a validator) is removed with the field |
| `canonical_arena_lookup`, `canonical_arena_same` (118-131) | the process-global table | **removed** with the family arenas (§9) |
| `fresh_lifetime()` | `MOV dest, SP` | unchanged in meaning (names a local lifetime); its lowering is the frame witness too |

`emit_region_bump_check` and `L_region_grow` (prims_memory.silica:159-185 and the grow helper) have no remaining caller in emitted user code once the mailbox-buffer copier stops using region blocks (§5.1); they are deleted from the four emitters.

### 3.3 Return: destination-passing where the compiler sees the flow, evacuation otherwise

The 2026-10-12 result slot stays: a function returning a tuple or record of **static size** gets the caller's slot address in X8 (x86-64: `rbx`, the emitter's X8 mapping, `linux_x86_64/regs/README.md` §2 "the aggregate-return (sret) pointer; must cross a call", set up by `terms/call.silica@sret_x8_setup` 180-210 and parked by `emitter_core@sret_save_x8` 2695; the SysV hidden-sret convention applies only at the FFI boundary; ESP32-S3: the emitter's result pointer register) and builds the shell there (`term_user_call_abi@user_call_aggregate_return_alloc_bytes`, 113-134; `sret_save_x8`, `sret_tuple_epilogue_copy` in emitter_core.silica:3270-3285). That is destination-passing in its literal form and it covers every result whose size is known at compile time: a `(:reply, r, s)` tuple, a record shell, a tuple of scalars and pointers.

What the slot cannot hold is a result whose size is only known at run time: the new nodes of a persistent update (O(log n) nodes), a list built by recursion, a concatenated string. On one downward stack **a callee cannot build such a result inside its caller's frame**: the caller's frame is above the callee's, the destination's size is unknown when the callee frame is pushed, and the callee's own frame sits between the caller's SP and anything the callee allocates. So "build where the result is kept" has two realisations, both decided at compile time per call site:

**(a) Frame adoption (destination-passing in stack form), for a call in return position.** A call is in *return position* when its result is the enclosing function's result, directly or wrapped only in fresh allocations that are themselves in return position: the body's tail expression, the tail of a `let` body, a `case` arm's tail, and an operand of a `tuple_make` / `record_make` / `list_cons` / `alloc_rec` / `string_concat` that is in return position. (A kind-5 call that is the body's tail is a tail call and keeps today's TCO, `emitter_core@tco_eligible` 1679: the callee replaces the frame, nothing to adopt.) For a return-position call the callee's epilogue restores the callee-saved registers and LR from the fixed part but **does not restore SP**: the caller continues with SP where the callee left it, so the callee's dynamic part (the result's nodes) is now the bottom of the caller's dynamic part. No copy. The callee's dead fixed part stays between; it is garbage that the next evacuation drops, and it never raises the peak: every adopted frame was live at the deepest point the call reached, so the memory it keeps was already committed.

Why this is the stack form of destination-passing: the result is built exactly where the caller keeps it, contiguous with the caller's own allocations, and it is handed up through any number of return-position frames with zero copies. The recursive `map`, `[f(h) | map(f, t)]`, whose evacuate-per-level cost would be quadratic (requirements R4.3, design §19.5), costs nothing per level and one evacuation at the consumer.

How the compiler marks it: the SIR generator tags a return-position kind-5 call `|rp` (a metadata suffix in the node's value string, as `|mv` and `|_mvs=` are today, term_message_copy.silica:509-518). The emitter then (i) at the call site emits no post-call `ADD SP` for argument or sret slabs, and (ii) selects the callee entry that does not restore SP. Because a callee does not know whether a given call is in return position, every function with a pointer-carrying result gets **two epilogue labels**: `L_<fn>_ret` (full restore) and `L_<fn>_ret_adopt` (no SP restore); the caller passes which one it wants in the frame-marker word the emitter already reserves next to X8 (one bit of the sret slot word), or, simpler and chosen here, the callee always ends with the adopting epilogue when its result type carries pointers and the **caller** restores SP itself after a non-adopting call (`MOV SP, X29`-relative: the caller knows its own fixed frame size, `frame_spill_nbytes` at emitter_core.silica:3119). The second form needs no new epilogue and no flag; it is the one the design chooses. A caller of a pointer-returning function therefore has, after the `BL`, either nothing (return position) or the evacuation sequence of (b).

**(b) Evacuation at the consumer, for a call whose result is bound or used.** The consumer is the first frame where the result does not flow to the return: it is bound by a let and used, passed as an argument, stored in a slot, compared, destructured for a part. There the emitter inserts, right after the `BL`, a call to the target's evacuation routine (§3.5) with the result value and its type descriptor; the routine copies the result's new nodes (those below the caller's pre-call SP, that is, in the callee frame and any frames it adopted) into the caller's dynamic part, then resets SP to just below them. Nodes above the pre-call SP (the caller's own earlier nodes, older frames, the state area, mailbox buffers, literals) are left where they are and pointers to them are kept.

The same two cases apply to the **behaviour function itself**: its result `(:reply, r, s)` is a static tuple in the runtime's slot (X20, `use_actor_reply_sret_buffer`), and `s` is the new state root; the dispatch-end evacuation of §4 is case (b) with the state area as the destination, and `r` is copied to the caller by §5.3.

### 3.4 Where the compiler sees the flow: the return-position analysis

The analysis is syntactic over the function's SIR and needs no flow sensitivity:

```
rp(node) :=
  node is the body root                                   -> true
  node is the right_expr (body) of a kind-2 let whose parent is rp   -> true
  node is the tail of a kind-8 case arm of a kind-3 case that is rp  -> true
  node is an operand of a kind-6 tuple_make / record_make / list_cons /
       alloc_rec / string_concat / move that is rp                   -> true
  otherwise                                               -> false
```

A kind-5 user call with `rp(call)` true and the call not the TCO tail is marked `|rp`. A call whose result type is pointer-free (`term_message_regions@type_is_pointer_free`, 135) is never marked: nothing to adopt. A call inside a `case` scrutinee, a let's right-hand side whose name is later read, an argument position, or a comparison is not in return position and is evacuated at that site.

Cost of a wrong classification: none for safety, only for memory. Marking too little evacuates where adoption would do (copies); marking too much is impossible by construction because the predicate is syntactic.

### 3.5 The evacuation routine

One runtime routine per target, `_silica_rt_evacuate(value, descriptor, boundary, dest_kind)`:

- `value`: the root word of the returned (or kept) value; a scalar or atom (below 65536) returns at once.
- `descriptor`: the type descriptor of the value (§3.6); the walk is type-directed, exactly as `L_mc_root` is.
- `boundary`: the lowest address that is **old**: for a return it is the caller's pre-call SP; for a dispatch end it is the state edge (§4). A pointer at or above the boundary, or outside the stack reservation entirely (a mailbox buffer, a literal, the FFI arena), is old for a return and left alone; for a dispatch end everything not in `[edge, top)` is new (§4.2 says what is excluded).
- `dest_kind`: 0 for a frame return (destination: the caller's dynamic part, below the pre-call SP), 1 for the state area (destination: exact-size holes then the edge, §4.3).

The walk is **two passes** on hosted targets and one pass on the ESP32-S3:

1. **Scratch pass.** Walk the value from its root. Every new node is copied to a scratch block placed below the current SP (which is below every source node: on a return SP is the callee's frame bottom and every deeper frame has already returned; at a dispatch end SP is the behaviour frame's bottom and the scratch starts at the bottom of the committed run, §4.2). As each new node is copied, its **final address** is assigned at once (frame return: a running cursor from the pre-call SP downward; state: an exact-size hole or the edge, §4.3) and written into the node's forwarding word (§3.6) in the dead source; pointers inside the copy are written as final addresses, using the forwarding word when a source node has already been visited. So the scratch copy already contains final pointers, and sharing is preserved without a table wherever a node has a forwarding word.
2. **Placement pass.** Copy each scratch node to its final address. Nodes destined for a contiguous run (a frame return: all of them; a state evacuation: the edge-bound nodes) are laid out in scratch in final order, so that run is one `memcpy`; hole-bound nodes are copied one by one. No pointer is adjusted in this pass. Decision 20's "adjusting pointers by a constant offset" becomes a zero adjustment because the final addresses are assigned in pass 1; decision 21's holes are what makes assigning them in pass 1 necessary, and the two decisions are consistent in this form.

Why two passes on hosted targets: the final destination (just below the caller's pre-call SP, or the state edge) overlaps the dead frames where the sources and their forwarding words still live; copying straight to the destination could overwrite a source not yet walked. The scratch region is below everything that is live or still to be read, so pass 1 never overwrites a source, and pass 2 may overwrite anything below the boundary because the sources are dead by then. On the **ESP32-S3** the destination of a state evacuation is a heap block of the state chain and the destination of a frame return is the caller's chunk, neither of which overlaps the source chunk, so the routine copies straight to the final address in one pass (§2.6).

**Cost** of one evacuation: one type-directed walk over the reachable new nodes (one descriptor entry read per word), two copies of the new bytes on hosted targets (one on the board), one forwarding-word write per new node, and table work only for the one node kind that has no forwarding word (REF1 scalar cells, §3.6). Unreachable nodes of the dead frames (intermediate versions, dead locals, adopted fixed parts) cost nothing. For a persistent update returning k new nodes that is O(k) work; for a result that was adopted through d frames and then consumed, O(k) once, not O(k·d).

### 3.6 Node kinds, descriptors and forwarding words

The copier's descriptors (term_message_copy.silica:26-50, KIND 0 to 6) are extended and reused by the evacuation routine. Every node kind that can be shared (reached twice) needs a **forwarding word**: a word in the live node that is never a scalar the program chose, so that a forwarding pointer written into it is told apart exactly. The design uses bit 63: a forwarding pointer is stored as `addr | (1 << 63)`; no live value of any forwarding word below has bit 63 set.

| Kind | Node layout (today) | Forwarding word | Why exact |
| --- | --- | --- | --- |
| 2 REF1 (`alloc_ref` scalar cell) | one word, the scalar | **none**: the cell's one word is an arbitrary scalar | the evacuation routine keeps a per-call table for REF1 cells only (the copier's open-addressing table, term_message_copy.silica:973-977); REF1 cells are rare (two stdlib sites: wbt_map.silica:7341, wbt_set) |
| 3 REFTUP (`alloc_rec` cell + payload) | +0 pointer to the payload at +8, payload words | +0 | a live cell word is a pointer (bit 63 clear) |
| 4 AGG record | +0 shape word (an atom index), fields | +0 | a shape word is below 65536 |
| 4 AGG tuple (by value) | element words | **none**; tree-shaped, copied without bookkeeping, as the copier does today | a by-value tuple has one owner in the type system; the copier already assumes this (R4.2 names refs as the shared kind) |
| 5 SUM | matched by its first word (tag atom or shape) | as the alternative's layout | — |
| 6 BUF | `[-8]` element count, elements | the count word | a count is non-negative (`L_buf_invalid` rejects negatives) |
| **7 LIST** (new, decision 30) | handle 24 B: length, chunk pointer, cursor; chunk `CDATA + 16`: slots, next, claim (prims_list.silica:21-32, 606-616) | handle: the length word; chunk: the **claim** word (a small byte offset) | lengths and claims are small non-negative numbers; a chunk is one node copied whole (slots 0..CDATA, next, claim), so two handles into one chunk keep sharing it |
| **8 STRING** (new, decision 29) | 24 B header: `-1` marker, byte pointer, length; bytes follow (string_concat_mmap_nomte.silica:48: `ADD X0, X21, X22; ADD X0, X0, #25`) | the marker word | a run-time string's marker is `-1`; a **literal**'s marker becomes `-2` (proposal, implementation detail: `string_rodata` emits the literal headers) so that the walk never copies a literal (decision 29: literals are only pointed to) |
| **9 CLOSURE** (new) | a function value with captures: code pointer, environment record | the environment record's shape word | today the copier treats function values as WORD; a returned closure that captures frame data is an open defect (memory note "returned closure loses capture"); giving closures a described environment closes it. Until closure environments are emitted as described records this kind is rejected at a send or return by E2300 (§6.4) |
| 1 REGION | an owned region handle | — | **retired**: a region is a lifetime witness word (§3.2) and is copied as a WORD; it points at nothing |
| 0 WORD | scalars, atoms, actor refs, type parameters | — | copied as is. Decision 38: no `ref?(L, S, rec)` with an unbound `rec` can reach a descriptor once Q19 is enforced (§5.1); the KIND 0 sharing of unbound refs is closed. |

**Descriptor emission.** Today a descriptor is emitted per send site from the message type string (`md_descriptor_rodata`, term_message_copy.silica:483-490). Under the design every function with a pointer-carrying result type gets one descriptor for its result type (label `L_td_<fn>`), every behaviour one for its state type (`L_td_<fn>_s`) and one for its reply type, every spawn site one for the initial-state type, and every send site one for the message type, all built by the same module from the type string; identical types share a descriptor through the module's existing label scheme. Descriptor size is a few words per field; the compiler's giant inline record types (the atom-table record appears in hundreds of signatures) produce one descriptor per **distinct** type per module, so the rodata cost is bounded by the number of distinct pointer-carrying types a module mentions.

### 3.7 Strings and list cells in frames (decision 29, §7.5 item 8)

**Strings.** `L_concat_helper` (string_concat_mmap_nomte.silica:48-76) computes the exact result length before it allocates (`ADD X0, X21, X22; ADD X0, X0, #25`), so the design changes only its allocation: the `L_sc_bump_alloc` arena, its lock, the 4 MB mmap chunks, `L_sc_arena_mark` / `L_sc_arena_release_to` / `L_sc_arena_release` and the `L_sc_len_key` cache are **deleted**, and the helper allocates `24 + len + 1` rounded to 16 **in the caller's frame**. A helper cannot `SUB SP` for its caller, so `string_concat` is emitted as: `MOV X0, a; MOV X1, b; BL L_concat_len` (returns the rounded size in X0, or 0 when one operand is empty and the other is returned as is), frame allocation of X0 bytes (§3.2), `MOV X2, SP; BL L_concat_into` (copies both operands into the block at X2 and returns it). Two helper calls instead of one; no lock (the frame is the actor's own), no shared arena, and the compile-time memory campaign's finding that the string arena was never freed (memory note "Emitter core 4 GB campaign") becomes release at frame pop. `substring`, `substring_until_char` and every other string prim that allocates follow the same pattern. The other targets' twins (`string_concat_*` in linux_aarch64, linux_x86_64, and the board's console-free string helpers) change the same way.

Returning a string evacuates it (STRING kind: header plus bytes, one node); keeping it in state copies it to the base; a literal is pointed to. A string built by an accumulating loop (`acc <- concat(acc, piece)` in a tail-recursive function) allocates every intermediate string in the frame the loop runs in, as the arena did, and frees them all when that frame pops: total allocation is quadratic in the final length exactly as today, and the peak is bounded by the frame instead of the actor's life. §11.2 names this as a risk for the compiler's own emitter units and how it is measured.

**List cells.** `L_list_prepend_helper` (prims_list.silica:606-700) allocates a 24-byte handle and, in two of its three paths, a chunk of `CDATA + 16` bytes. The helper is rewritten to **take its memory from the caller**: the emitted `list_cons` sequence allocates `24 + CDATA + 16` rounded to 16 in the frame before the `BL` and passes the block in X6; the helper uses the chunk part only on the `L_lph_cow` and `L_lph_new_chunk` paths and leaves it unused on the `L_lph_room_stored` path (a slot in an existing chunk: that chunk may be in an older frame, the state area or a mailbox buffer, and writing a free slot of it is the mutation lists already do; the claim word rule of prims_list.silica:610-616 stays). The unused chunk part is frame garbage dropped at the pop or by the next evacuation; the alternative, two allocations with a branch, costs a second `SUB SP` and buys 48 bytes per prepend-into-free-slot. `emit_list_head_box` (442-453) boxes an aggregate head by frame allocation instead of `_silica_rt_region_alloc`. `L_list_tail_helper` allocates a handle (the 24 B per `.tail`, memory note "List walk allocation"): the same caller-provided block, 32 bytes.

**Checked int64** (`prims_checked_int64.silica:72`, the `(ok, value)` pair): a frame allocation of 16 bytes, or no allocation when the pair is destructured at once (today's X8 path).

### 3.8 `alloc_region` as a frame area and what a region parameter means now

With the handle a lifetime witness (§3.2), "a region is an area in the current frame" (decision 34) means: every `alloc_*` into any region handle allocates in the **frame that executes the prim**. This has one consequence the decisions do not spell out and §13 records as a problem for Lee's attention: a callee that receives a region parameter `r: region(L, normal)` and allocates into it allocates in **its own** frame, not the caller's, so the result reaches the caller only by return (evacuated, correct) and never by `write_ref` into a cell the caller owns (the cell would point into the popped frame). §6.3 gives the checker rule that makes the second case a compile-time error (E2302). Returning a region handle, sending it, keeping it in state: the witness word is copied like any scalar and the values typed with its lifetime are evacuated or copied by the type-directed walk; nothing about the region itself is copied, because it owns no memory.
## 4. Dispatch end: compiler-proven release, the fallback, evacuation into the state area

This section settles §7.5 items 1, 2 and 5. A **dispatch** is one behaviour call: from the runtime's `blr x8` (`prims_actors_runtime_asm.silica:762`) to the behaviour's return. At its end exactly one value is live: the new state `s` (decision 18); the reply has been copied to the caller (§5.3) and every frame is dead.

### 4.1 The per-behaviour use analysis (decision 18)

**What the proof must establish.** Let the state type be `S`. A **slot** is a position of `S` whose type is a structure or any other node-bearing type (`ref`, `ref?`, `List`, `string`, `buf`, a record or tuple containing one), reached from the state root only through by-value aggregates (records, tuples, sums): a state `{ m: <map>, cfg: { names: List[...], n: int64 }, h: <heap> }` has slots `m`, `cfg.names` and `h`. The *lineage* of a slot during one dispatch is the sequence of versions derived from the old slot value by updates. The proof establishes, for every slot:

> **(P1)** the versions derived from the old slot value form one chain `v0 → v1 → … → vk` (each `v(i+1)` is the result of exactly one update whose version input is `v(i)`), with no branch and no second update of any `v(i)`;
> **(P2)** exactly one of `v0 … vk` reaches the new state, and it reaches exactly one slot of the new state; if `k = 0` no update happened;
> **(P3)** no version `v(i)` with `i < k` reaches the new state through any other route (a closure, a ref cell written during the dispatch, a `List` or record built around it), and no value *read out of* a version (an inner structure obtained by a call on it) reaches the new state at all;
> **(P4)** every update in the chain is a **logging update**: a call to a function whose body (transitively, within this unit or through its interface) allocates replacement nodes only through `retire`-paired allocation (§4.2).

When (P1)–(P4) hold for every slot, every node that the chain's updates retired is unreachable from the new state: a retired node lies on a copied path of some `v(i)`, `v(i+1)` does not reference it (that is what path copying means), no later version does (immutable structures never point from old nodes to new, and each later version is built from the previous one), and no other route keeps it (P2, P3). Nodes of `v0` that were never retired are still referenced by `vk` or are not, and if not they were never on a copied path, so they are reachable from `vk`'s shared structure: nothing is freed that is live and nothing live is counted as garbage. That is the correctness argument in full; §13 item 1 records the one assumption it rests on (no run-time sharing between slots).

**What counts as an alias.** The analysis is a taint closure over the behaviour's SIR, of the kind `term_message_copy@fn_copy_markers` already computes (`mc_closure`, `term_message_copy.silica:584-655`), with these sets per slot `q`:

- `Old(q)`: the parameter name `state` projected to `q` (a chain of `record_proj` / tuple decomposition / case `bind` arms on the state); every let whose right-hand side is such a projection; every `bind` arm over such a scrutinee. These names denote `v0`.
- `Ver(q)`: `Old(q)` plus the result names of **update calls** whose version argument is in `Ver(q)`. An *update call* is a kind-4 or kind-5 call to a function whose result type carries a pointer and which has a `|_upd=<i>` marker (§4.2: the callee is a logging updater and its version parameter is parameter `i`); the result is bound by a let or destructured through the reshaped sum (`(:inserted, m2)` arms of §8.3), and the arm bindings are the version names.
- `Alias(q)`: every other pointer-carrying name derived from a name in `Ver(q)`: the result of any *other* call that takes a `Ver(q)` name (an inspection returning a structure, such as `get`), a projection out of a version (`v.root`), a `case` arm binding over a version or a projection of it, a tuple/record/list that packs a version name, a function literal that captures one, and any name bound to an expression mentioning one of these (the closure in both directions as `mc_closure_step` does). An **inspection call** whose result type is pointer-free (`type_is_pointer_free`) creates no alias.
- `Sink`: the names and expressions that reach the new state `s'`: the third element of the `(:reply, r, s')` tuple or second of `(:no_reply, s')` (`mc_reply_needs_copy` already finds these positions, 752-791), closed backwards through lets, aggregate constructors, calls whose result carries pointers (conservatively: a call result in the sink makes every pointer-carrying argument a sink), `write_ref` targets reachable from the state (a `write_ref(c, v)` where `c` is in `Old(q)` or `Alias(q)` puts `v` in the sink), and closure captures.

The proof for slot `q` holds iff: (i) exactly one name of `Ver(q)` is in `Sink`, and it is the last of its chain (its result was not the version argument of another update call); (ii) every name of `Ver(q)` other than `v0` is the version argument of at most one update call, and `v0` is the version argument of at most one update call; (iii) no name of `Alias(q)` is in `Sink`; (iv) the sink name occurs **once** in `s'` (one slot). A pattern arm over a version that is not a plain `bind` (a record, tuple or list-cons pattern over a scrutinee in `Ver(q)`) poisons the set, as `mc_case_arms_step` does with `"!"` (637-640), and fails the proof: its bindings would be aliases the analysis cannot name. A version passed to a call that is neither an update call nor pointer-free in its result is an alias (`Alias(q)`), so passing a version to a user function that returns a record containing it counts as a kept alias if that record reaches the state: conservative and sound.

Slots that are not updated in the dispatch (`k = 0`): trivially proven if `v0` reaches exactly one slot of the new state (`{ ... m: state.m ... }`), or does not reach it at all (the slot is replaced by a fresh value or by a message part: then `v0`'s nodes are garbage and **are not freed** by the log, because no update retired them; see "What release does not cover" below).

**Flow sensitivity.** The analysis is flow-insensitive except for the chain order, which it reads from the let nesting (a let's right-hand side is evaluated before its body); a `case` with an update in one arm and none in another is proven per arm (each arm is a separate body for the chain, joined at the arm's result), and the proof must hold in every arm. The behaviour is **proven** when every slot is proven in every arm; otherwise it is **unproven**, and the first failing condition with its name and location is the diagnostic's text (§4.5).

**What release does not cover (by design).** A slot whose old value is simply dropped (`{ m: wbt_map@empty_map(), ... }`) frees nothing through the log; its nodes stay in the state area until a fallback copy compacts them. Under a proven behaviour there is no fallback copy, so a behaviour that replaces a slot wholesale rather than updating it leaks that slot's nodes for the actor's life. The analysis therefore treats **a dropped non-empty slot as unproven** ("slot `m` is replaced without an update; its old nodes cannot be released"): the behaviour then uses the fallback, which compacts. Proposal (behaviour-affecting): this is the conservative reading of decision 4 ("where it cannot prove that, the fallback"); Lee may prefer to accept the leak and keep the behaviour proven, which §12 lists as the alternative.

### 4.2 `retire`, logging updaters and the release log

**The log.** A per-actor array of `(node, size)` entries (§2.2: #536/#544/#552; board `ACB_SLOG`). The behaviour's prologue, emitted for a **proven** behaviour only, stores 1 to `#560` (board: `ACB_SFLAGS`) and 0 to `#544`; the dispatch-end routine reads the log and frees each entry into the free list of its size (§2.3), then stores 0 to `#560`. For an unproven behaviour the prologue stores 0 to `#560` and nothing is logged: `retire` is then three instructions (load flag, test, branch).

**`retire(r)` (proposal — Lee to confirm, a new builtin).** `retire(r: ref(L, S, T))` and `retire(r: ref?(L, S, T))` are prims with effect `proc[mem(S)]` and result `unit`. Emitted sequence (AArch64): `LDR X9, [ACB, #560]; CBZ X9, skip; LDR X10, [ACB, #528]; CMP X1, X10; B.LO skip; LDR X11, [ACB, #528+top]; ...` — precisely: test the enabled flag, test `edge <= r < top` (the node is in the state area; a node in a frame or a mailbox buffer is never logged because it dies with its owner), then append `(r, size)` to the log, growing the array by `realloc` to double capacity when full. The size is the static size of `T`'s node (REFTUP: `8 + words*8`; REF1: 16; a buffer or string: its run-time length word is read). The ACB is reached through `_silica_rt_tls_current_actor_get` as the boundary move does today (`behaviour_result_move_asm`, `[SP]` = ACB); the emitter caches it in a frame slot per function that retires, so the per-call cost is one load. `retire` on `:none` or on a node already retired in this dispatch: the second case cannot happen in a chain (each node is on one copied path once); the prim does not test for it, and a stdlib updater that retires a node twice is a bug caught by the allocator-probe trial (§11.3).

**Logging updaters and the `|_upd=` marker.** A function is a *logging updater* when its body, or a callee's in this unit, contains `retire`, and its result type carries a pointer; the SIR generator marks its *version parameter* (the first parameter whose type is the same structure type as the result's version) with `|_upd=<index>` in the function's effects string (where `|sir_rec:` metadata already rides, `recursion_terms.silica:46-51`), and the interface file (`.iface`) carries the marker so that callers in other units see it. The stdlib families are the logging updaters (§8.2); user-written persistent structures become logging updaters by calling `retire` where they replace a node. A behaviour that updates a state slot through a function with no marker is **unproven** for that slot ("`insert_all` is not a logging updater"): the rule of (P4).

**Which stdlib updaters log, and how they know a node is in the state area.** They do not know; `retire` knows (the range test). Every family's node constructor helper (the one `alloc_rec` per family, §8.1) gains a *replacing* form used on copied paths: `replace_node(old, fields)` = `retire(old)` then `alloc_rec(fields)`; `delete` and `pop` retire the removed node as well; rotations retire every node they rebuild. The change is mechanical per family and §8.2 lists the sites. A no-op change (`:unchanged`) retires nothing because it allocates nothing.

### 4.3 Evacuation of the new state (decisions 20, 21)

At the behaviour's return, after the reply copy (§5.3) and before the release algorithm, the emitted epilogue calls `_silica_rt_state_evacuate(s', L_td_<beh>_s)` (the routine of §3.5 with `dest_kind = 1`, `boundary` = the state area). Its walk, from the new state root:

1. A word that is not a pointer (below 65536) is copied as is. A pointer into `[edge, top)` is an **old state node**: kept, not followed (nothing new can be reached through an old node, because old nodes never point at new ones; a `write_ref` into an old cell during the dispatch is the one exception and is covered by §6.3's rule, which makes the written value an old-state value too). A pointer anywhere else (a frame, the mailbox buffer, a literal marked `-2` which is skipped, the FFI arena which is skipped by range) is a **new node**: copied.
2. A new node already forwarded (bit 63 of its forwarding word set) contributes its final address; otherwise it is assigned a final address now (an exact-size hole, else the edge), copied to scratch with its pointers resolved recursively, and its forwarding word written. The REF1 table serves REF1 cells (§3.6).
3. Pass 2 places the scratch nodes (§3.5). Edge-bound nodes are laid out in scratch in descending final order so that they form one block copied by one `memcpy` to `[new_edge, old_edge)`; hole-bound nodes are copied singly.
4. `#528 = new_edge`, `#568 += bytes placed`, `ACB #0 = the root's final address` (or the scalar).

Then, for a proven behaviour, the release log is drained: each `(node, size)` goes on its free list and `#568 -= size`. Order matters: holes freed by this dispatch's retires are **not** available to this dispatch's evacuation (the log is drained after), which keeps step 2 independent of the log; the holes serve the next dispatch. The alternative order (drain first, then evacuate into the holes) would reuse a retired node's memory in the same dispatch and is equally correct; the chosen order is simpler to verify because during evacuation every old node is intact, retired or not.

**Costs.** One descriptor walk over the new nodes (reachable from `s'` and not in the state area), two copies of their bytes (one on the board), one forwarding write per new node, free-list pops for holes, one `memcpy` for the edge block, and for a proven behaviour `O(retired)` free-list pushes. Nothing proportional to the state's size is read or written, which is decision 4's requirement for the proven path.

### 4.4 The fallback: whole-state copy via scratch (decisions 19, 28)

For an **unproven** behaviour the epilogue calls `_silica_rt_state_copy_all(s', L_td_<beh>_s)` instead:

1. Walk `s'` with the **copier's table** (not forwarding: the old state's nodes must stay intact while being read, and the old state's sharing must be preserved across the whole copy): every node reachable from `s'`, old or new, is copied into scratch with final addresses assigned from a fresh cursor that starts at `top - 1040` (a brand-new state area laid over the old one, holes gone). One table per **slot** of `S` (§4.1's slots): a node reachable from two slots is copied twice, so that slots never share nodes afterwards (the invariant §13 item 1 needs); within a slot sharing is preserved.
2. Pass 2 copies the scratch block to `[top - 1040 - bytes, top - 1040)`; the free-list header is zeroed (129 words); `#528 = new_edge`; `#568 = bytes`; `ACB #0 = root`. The old area is simply overwritten: nothing in it is live.
3. The copier's table is freed (`malloc`/`free` as `L_mc_root` does today, 905-908: the table is runtime-private and proportional to the number of shared nodes).

Peak memory while copying is the old area plus the scratch block (about twice the state, decision 28); the cost is two copies of the live state plus the table work for shared nodes, every dispatch of that behaviour. The board copies once into a fresh state chain and returns the old chain to the heap.

### 4.5 The compile-time note and strict mode (decision 19; §7.5 item 2)

**Proposal — Lee to confirm (user-visible).** When a behaviour is unproven the compiler prints a **warning** (the compile succeeds), using the existing W-code class (`print_compiler_warning`, `diagnostics_core.silica:138`; precedents W2201, W4001):

```
RegionWarning at <file>:<line>:<col>
W2300

state release not proven for behaviour 'beh': <reason>. Every dispatch of this behaviour copies its whole state at dispatch end (cost proportional to the state's size). spec:§15.1.1
```

where `<reason>` is one of: `'<name>' aliases the old state and reaches the new state (line N)`; `slot '<q>' is updated twice from version '<v>' (lines N, M)`; `version '<v>' is kept twice in the new state`; `'<fn>' is not a logging updater`; `slot '<q>' is replaced without an update`; `pattern on '<v>' at line N hides its parts`. W2300 is the first number of the E23xx region family's warning space; the family's error numbers run to E2318, with E2319/E2320 retired and not reused.

**Strict mode** turns W2300 into error **E2321 StateReleaseNotProven** (the next unused number of the family) with the same text. Spelling (proposal, two forms, Lee chooses): (a) the environment variable `SILICA_STRICT_STATE_RELEASE=1` read by the driver, which costs no syntax and matches how the runtime takes its knobs (`SILICA_IDLE_RELEASE_MS`, `SILICA_CARRIER_COUNT`); (b) a module-level declaration `strict state_release;` after the `module` line, which puts the choice in the source where Lee's nothing-hidden rule would have it but needs a parser and module-checker change. The compiler reads no environment variable today (survey §5), so (a) is the first time it would; (b) is the form consistent with "nothing hidden". The design recommends **(b)** and implements (a) only if Lee prefers it. **[Confirmed by Lee 2026-10-24: (b), `strict state_release;`; the environment variable is not used.]** Which behaviours are proven is otherwise invisible: no code is emitted differently in the user's program except the behaviour's prologue flag and its epilogue routine.

### 4.6 Order of operations at dispatch end

The dispatch loop (`prims_actors_runtime_asm.silica:858-921`) and the behaviour epilogue (`behaviour_result_move_asm`) together do, in this order:

1. behaviour epilogue: reply copy into the caller's stack (§5.3), when the node needs a reply;
2. behaviour epilogue: `_silica_rt_state_evacuate` or `_silica_rt_state_copy_all`, then the release-log drain (proven only); `ACB #0` now holds the new root;
3. behaviour epilogue: mailbox-buffer release unless forwarded (§5.1); then return to the runtime;
4. runtime: `_silica_rt_stack_on_message_return` (the release algorithm, now measuring from the new edge);
5. runtime: reply handoff (`reply_set`, wake), node free, requeue, as today.

Steps 1 to 3 run on the actor's stack inside the behaviour frame, where the state descriptor and the result tuple are at hand; the scratch of §2.5 lies below that frame. `bmv_state_asm`, `bmv_state_reuse_asm` and the tagged-block scheme (`prims_actors.silica:594-656`) are deleted: the state is never "moved" again, only evacuated or copied.
### 4.7 The state policy: how the state area gives memory back (decision 40; P15 confirmed by Lee 2026-10-24)

**The three choices** (spawn argument `state_policy(…)`, required, no default; the value is in the ACB, §2.2, so the dispatch-end routine reads one word):

| Choice | When the edge moves up and pages are decommitted | Cost |
| --- | --- | --- |
| `:keep_state_area` (0) | never while the actor lives; holes are reused by the free lists (decision 21) and the area keeps its largest size | none |
| `:shrink_after_compaction` (1) | whenever the fallback copy (§4.4) compacts the state: after the copy back, the edge is set to the compacted end and every page between the old and the new edge is decommitted (`MAP_FIXED` remap, as `_silica_rt_stack_release_to` does). A **proven** behaviour never takes the fallback, so for it this choice behaves like `:keep_state_area`; the W2300 note (§4.5) already names the behaviours that do compact | pages returned only when a compaction was going to happen anyway |
| `:compact_on_request` (2) | the behaviour calls the builtin `compact_state()` (effect `proc[mem(S)]`, unit result; name confirmed, P15): it sets `#584`; at the end of that dispatch the routine of §4.4 runs even for a proven behaviour (its release log is drained first, so the compaction copies only live nodes), then the shrink above | O(live state) for the dispatch that asked; none for the others |

**Where it happens.** In step 2 of §4.6, directly after `_silica_rt_state_evacuate` or `_silica_rt_state_copy_all` and the release-log drain: the routine reads `#576`; if the dispatch compacted (the fallback ran, or `#584` was set) and the policy is 1 or 2, it sets the new edge (`#528`) to the compacted end, empties the free lists (compaction leaves no holes), and decommits the pages from the old edge down to the new one. Step 4 (`_silica_rt_stack_on_message_return`) then measures from the new edge as before (§2.4). `#584` is cleared at dispatch end. A `compact_state()` under `:keep_state_area` or `:shrink_after_compaction` is not an error: it compacts and shrinks anyway only under policy 2; under 0 and 1 it is a no-op (the prim tests `#576`), which keeps library code that calls it correct under any caller's choice. All three are deterministic: the choice is data, the trigger is a code path, nothing is measured against a threshold.

**Board.** The state chain's chunks above the compacted end are returned to the heap (`silica_rt_chunk_next`'s inverse); byte 157 holds the choice, byte 158 the request.

**Compile-time.** A behaviour that contains `compact_state()` is treated as taking the fallback on the dispatches that call it, so the analysis of §4.1 still proves the remaining paths and W2300 is not reported for the requested compaction.

## 5. Messages, replies and spawn

This section settles §7.5 items 7 and 11.

### 5.1 The copier and the mailbox buffer (decisions 7, 30, 38; Q19)

**The copier** (`L_mc_root`, `term_message_copy.silica:899-982`) keeps its structure and gains:

- **A measuring mode.** `L_mc_measure(value, descriptor)` walks exactly as the copy does, with the per-message table, and returns the byte total of the copy (each node's 8-byte-rounded size; a shared node counted once). It exists so that a mailbox buffer and a reply (§5.3) can be allocated at their exact size before the copy. Cost: one extra walk per send.
- **A destination cursor.** `L_mc_root` takes a destination block and bumps inside it instead of reserving in "the current fresh region" (`L_mc_reserve`, 933-937) and allocating shells in an ACB arena (`L_mc_alloc_shell`); the pre-map of REGION words (`L_mc_premap`, 912-916), `L_mc_map_region`, `L_mc_is_canonical` and `L_mc_new_region` (919-928) are **deleted**: a region word is a lifetime witness copied as is.
- **KIND 7 LIST** (decision 30): the handle is copied (24 B) and every chunk from the cursor's chunk to the end of the spine is copied whole (`CDATA + 16` each), through the table so that two lists sharing a tail share it in the copy; the copy's claim words are set to each chunk's copied cursor so that the receiver's prepends start fresh chunks rather than writing into a chunk the sender also sees. Lists of inline aggregates (`list_elem_is_inline_aggregate`, prims_list.silica:399) copy their slots as AGG entries; boxed elements as pointers through their own descriptors.
- **KIND 8 STRING**: header plus bytes, one node, literal (`-2`) copied as a pointer.
- **KIND 9 CLOSURE**: rejected at compile time (E2300, §6.4) until closure environments are described; then copied as a record.
- **Q19 enforcement** (decision 38; §7.5 item 11): the type checker rejects an unbound `rec` (no enclosing tuple type) in binding annotations, record fields, parameter and return types with **E2010** (Q19, no new code), so every `ref?` the copier meets names its layout and KIND 0 is never a reference. The compiler's own sources and the stdlib carry `root: ref?(L, normal, rec)` in record fields today (every signature that mentions the atom table does); §11.1 phase 0 is the rewrite that spells the node shapes, and §11.5 names its compile-RAM risk.

**The mailbox buffer.** `send_deep_copy_asm` / `actor_message_copy_x10` (prims_actors.silica, the sites that copy into the sender's arena) become: measure; `malloc(bytes)` (board: `silica_rt_alloc`); copy into it; store the block's address at node `+8` (hosted) / `MSG_PAYLOAD` (board) and the byte count at a new node word (`+40` hosted, inside the 152 B node; board: a word at `MSG+40`, unused today) so that a forwarded buffer can be re-attached without re-measuring. A message whose type is pointer-free and fits one word is stored inline as today (no buffer). At dispatch end the behaviour epilogue frees the buffer (`free` / `silica_rt_free`) **unless** the dispatch forwarded it (§5.2) or kept a part: a kept part was evacuated by §4.3 (the buffer is outside the state area, so its reachable nodes are new nodes and are copied), after which the buffer is freed like any other. The buffer is never evacuated whole; what the state keeps is copied out of it once and the rest dies with the buffer. The nodes of the buffer are therefore addressed by the behaviour for the length of the dispatch and never afterwards, which is the dispatch scope of design §18.7.

**Failed send** (Q17, decision 7): a `cast`/`send`/`call` to a dead actor (`LBB3_dead_locked`, RT:1246; `LBB4_dead_locked`) frees the buffer with the node. **End-of-actor drain** (decision 31): `_silica_rt_actor_signal_pending_call_deaths` (RT:1286-1352) already walks the pending mailbox once and frees each node; it now also frees each node's buffer (one `free` per pending message, O(pending)); the board's `silica_rt_node_release_payload` (1025-1035) does the same for `MSG_PAYLOAD_OWNED` blocks. There is no owner list (decision 16): the queue is the list.

**`move(x)` in a send** (decision 6): copied like any send; the SIR's `|mv` tag (terms_actor_lowering.silica:485) is read only by the region checker (E2301, §6.2) and no longer changes the emitted copy. `md_prim_value_is_move` and `md_prim_is_move_wrapper` become dead in the emitter and are removed.

### 5.2 Forwarding-only elision: `|_mvs` and `|_mvr` reinterpreted (decision 32)

`fn_copy_markers` (term_message_copy.silica:820-833) today marks sends whose operand is a last use (`mc_site_is_last_use`) and replies that need no copy (`|_mvr=1`). Under the design:

- `|_mvs=<node>,` is set only when the send's operand is **the behaviour's whole message parameter** (SIR: a kind-1 var naming parameter 0 of a behaviour function, not a projection of it) and that parameter is a last use by today's rule (nothing evaluated afterwards mentions it or an alias) **and** no part of the message reaches the new state (the sink of §4.1 does not contain the message parameter or an alias of it). Then the emitted send hands the **mailbox buffer** itself to the new node: `node'+8 = node+8`, `node'+40 = node+40`, and the serving node's buffer word is zeroed so that the dispatch-end release skips it. One pointer move, O(1), decision 32's "handed on". A part of a message is never forwarded: a part has no buffer of its own (the message is one block), so "a part that owns its own buffer" in decision 32 has no instance in this design and the rule reduces to the whole message.
- `|_mvr=1` (the reply is not copied) is **removed**: every reply is copied into the caller's stack (decision 33), including one whose data is a parameter's or also in the new state. The only skip is the one that exists today for a `cast` that reached a call-style behaviour (`cast_skip`, prims_actors.silica:583: the node's needs-reply word is 0).
- `mc_site_is_last_use`, `mc_closure`, `mc_after` stay as the implementation of the "last use" test; `mc_reply_needs_copy` is deleted.

### 5.3 Replies into the blocked caller's stack (decision 33; the call record)

**The call record** is the call node (hosted: the 152-byte wrapper, RT:1396-1520; board: the 48-byte node, rt_actors.S:200-207, with `ACB_WAIT_NODE`). Hosted fields today: `+16` needs_reply, `+24` futex, `+48` parked carrier actor, `+56` caller ACB, `+72` lock (4 B), `+136` reply_set, `+144` reply. The design adds (hosted, within a node grown to **176 B**, proposal, not user-visible): `+152` the caller's **parked SP**, `+160` the reply's byte count, `+168` holders (2 at creation: caller and replier; the last to decrement frees the node). `reply_set` gains values: 0 waiting, 1 replied, 2 target died, **3 caller abandoned** (the future `call_with_timeout`, or a caller removed while waiting), **4 reply too large** (the caller's lowered reservation cannot take it). The board node gains `MSG_PARKED_SP` at +40 and uses `MSG_REPLY_SET` the same way.

**Parking.** A carrier actor already records its SP at ACB #464 when it parks (`_silica_rt_ctx_save`, CAR:1923-1943); the call path copies it to `+152` before unlocking the record. A dangerous actor or `main` on the futex path (`LBB4_7`, RT:1493) publishes `SP - K` to `+152` before `_silica_rt_cv_wait`, where `K` is the wait path's own frame depth plus margin (a per-target constant, 512 B on the hosted targets; the runtime's wait routines are leaf-ish and well under it), so that the replier never writes under a runtime frame. Nothing runs on a parked actor's stack below its parked SP until it is woken, which is what makes a foreign write safe.

**Replying.** The behaviour epilogue of the callee, where `bmv_reply_asm` runs today (prims_actors.silica:570-592):

1. lock `+72`; read `reply_set`; if 3 (abandoned) or 2: unlock, decrement holders, free the node if 0, skip the copy;
2. `bytes = L_mc_measure(r, L_td_<beh>_r)` (0 for a scalar: the scalar goes to `+144` directly as today);
3. `dest = (parked_sp - bytes) & ~15`; `_silica_rt_stack_grow_to(caller_acb, dest)` (prims_actors_stack_asm.silica:530: it takes the ACB explicitly, so a foreign stack is grown without faulting in the replier's thread); on return 1 (exhausted) set `reply_set = 4`, wake, unlock: the caller fails with `(:explicit, :stack_exhausted)` on waking (§10) [2026-10-24, decision 39: `:reservation_exceeded` for a lowered reservation, `:out_of_memory` under the default one]; for `main` (caller ACB 0) the destination is main's thread stack and no growth call is made (an overflow there is a fatal fault, status 70, as for any `main` stack exhaustion);
4. copy with `L_mc_root` into `[dest, dest + bytes)` (the copier's table, sources intact: the reply still lives in the replier's frame); store the root at `+144`, `bytes` at `+160`;
5. `reply_set = 1`; `_silica_rt_call_wrapper_wake`; unlock; decrement holders.

The caller, on waking (LBB4_8, RT:1506): reads `+144` and `+160`, sets `SP = parked_sp - bytes` so that the reply is the bottom of its frame's dynamic part (it lives in the caller's frame as the call's result and pops with it, decision 33), decrements holders, frees the node if 0, returns the root in X0. A `call` whose result is bound is then an ordinary frame value; one in return position is adopted like any other (§3.3).

**The board**: the caller is parked mid-behaviour with its chunk chain live (`silica_rt_actor_call`, 3842-3945); the replier allocates the reply **in the caller's chain**: `silica_rt_chunk_room(caller_acb, bytes)` returns space below the caller's SP in its current machine chunk, or takes a new chunk linked above `ACB_MCUR` when it does not fit (the same `silica_rt_chunk_take` the prologue check uses, with `CH_RET` unused); the reply node pointer goes to `MSG_REPLY`. The caller's chunk release at its own boundary frees it.

**Dangerous actors on their own threads** are callers and repliers like any other; only the parking differs (futex), handled above. A replier on a carrier thread writing into a dangerous actor's reservation and the reverse are both plain memory writes once the range is committed.

**`call_with_timeout`** (chunk 11, not started): the caller sets `reply_set = 3` under the lock when its timer fires before 1 arrives, decrements holders and leaves; the late replier finds 3 and drops the reply without copying (step 1). Nothing is allocated in the caller's stack by a dropped reply. The same path serves a caller removed while waiting (`_silica_rt_actor_signal_call_death`'s caller-side twin).

### 5.4 Spawn: initial state into the child's base (decision 15); Q14 child specs (decision 11)

**Plain spawn.** Today the spawner copies the initial state into its own arena (`spawn_init_move_asm`, prims_actors.silica:432-460) and the runtime stores the pointer (RT:151). Under the design `_silica_rt_actor_spawn` reserves the child's stack (`_silica_rt_actor_stack_reserve`, already in the spawn path) and then the spawner's emitted code copies the initial state **into the child's state area**: `bytes = L_mc_measure(st, L_td_<site>)`; `_silica_rt_stack_grow_to(child_acb, top - 1040 - bytes)`; `L_mc_root` into `[top - 1040 - bytes, top - 1040)` with one table per slot (the invariant of §4.4 step 1); `child #528 = top - 1040 - bytes`, `#568 = bytes`, `child #0 = root`. The child's first dispatch then finds its state where every later dispatch will: in its own stack base. A scalar or atom state needs no copy (`#0` holds it). The first page of the child's reservation is committed at spawn (today nothing is committed at spawn, spec §15.1.2.2 "nothing committed at spawn"): a 16 KB page per actor with a composite state; a scalar-state actor still commits nothing. §11.6 lists this as the one observable change to the stack contract and the specification line to amend.

**State policy (decision 40; P15 confirmed by Lee 2026-10-24).** Every spawning form takes `state_policy(:keep_state_area | :shrink_after_compaction | :compact_on_request)` as a required argument, directly after `stack_policy(…)` and before the optional core id: `spawn`, `spawn_registered`, `spawn_dangerous`, `spawn_dangerous_registered`, `spawn_device`, `spawn_device_registered`, `spawn_registered_supervisor` (and `spawn_supervisor` where the compiler has it), `spawn_state_machine`, and the supervisor child specs (`init` child lists, `add_child`: the spec carries the `state_policy` beside its `stack_policy`, stored in the row spec buffer, and every start or restart passes it again). `_silica_rt_actor_spawn` stores the choice in ACB `#576` (board byte 157) with the other policy words, before the state is copied into the child's base. A missing argument is **E2005**, as a missing `stack_policy` is today (the trials `error_enforcement_addition/stack_policy_missing_in_spawn` and `…_registered` show E2005 at the call, arity mismatch); no new code is needed, and `state_policy_missing_in_spawn` copies that pattern. A non-literal or unknown atom is rejected the way `stack_policy_release_not_literal` is today.

**Supervised children (Q14).** A child spec built by `init` is copied by the supervisor's `add_child` path into a **row spec buffer**: a `malloc`'d block of the spec's measured size attached to the row (the row payload words `+24` start.0 keep pointing at it; today they point into whatever arena built the spec, CT:29-30, 581, 715, a lifetime hazard the survey noted), freed when the row is removed or the child table freed (`_silica_rt_child_table_free`). Each start and restart (`_silica_rt_supervisor_spawn_child_row_by_flavor`, CT:428-438; board `rt_supervisors.S:408-505`) copies from the row spec buffer into the new child's state area exactly as a plain spawn does: cost proportional to the spec's size per start (decision 11), and the child's death releases it with its stack. The board already copies a composite init state per restart into a fresh heap block (421-436); it now copies into the child's state chain instead.

### 5.5 Cost summary for messages

| Operation | Walks | Copies | Allocation |
| --- | --- | --- | --- |
| `cast`/`send`/`call` message | measure + copy (2) | 1 (into the buffer) | one `malloc` of the exact size |
| forwarded whole message | 0 | 0 | 0 |
| reply | measure + copy (2) | 1 (into the caller's stack) | 0 (the caller's reservation; one `grow_to`) |
| spawn / restart state | measure + copy (2) | 1 (into the child's base) | 0 (the child's reservation) |
| dispatch end, message buffer | 0 | 0 | one `free` |
| end-of-actor drain | O(pending) | 0 | O(pending) `free` |
## 6. The lifetime-only region checker (decision 16; §7.5 item 9)

### 6.1 Which pass, what it computes

A new directory `compiler/src/region_checker/`, invoked in `main_compile_pipeline.silica` between the effect check (`:257`) and SIR generation (`:268`), on the model of `ffi_taint_checker@validate_program_ffi_taint` (`:247`: it takes the AST, prints its own diagnostics through `diagnostics_core@print_compiler_error`, returns an int64 and the pipeline returns `(1, dummy_sir_module())` on a non-zero result). It also receives `tc_out.context`, because it needs each binding's type. It is **report-only at first** (§11.1 phase 3): it computes and prints what it would reject without failing the build, under the same strict-mode switch as §4.5 (proposal: `strict region_check;` beside `strict state_release;`, or the environment variable), and becomes enforcing in phase 5.

Per function body it computes, flow-sensitively over the let nesting and case arms:

- **Frame set** `F`: names whose value may hold a pointer into the current frame: every name bound to an `alloc_*` result, a call result whose type carries a pointer (evacuated into this frame), a `tuple_make`/`record_make`/list literal/concat result, a projection of a name in `F`, a `bind` arm over a scrutinee in `F`; closed as a taint set. Parameters are **not** in `F` (their memory is older), nor are projections of parameters.
- **Moved set** `M`: names given to an explicit `move(x)` in a send, reply or spawn state (the SIR `|mv` tag, `terms_actor_lowering.silica:485`), with the move's location and, inside a `case`, the arm; closed over aliases as `F` is (a name bound to an expression mentioning a moved name is moved).
- **Lifetime binding**: for every lifetime name `L` in the body, whether it is *bound here* (by an `alloc_region` binding annotated `region(L, S)` or `fresh_lifetime()`) or *a parameter lifetime* (appears in a parameter type), per spec §12.1.4's rule that the lifetime comes from the annotation.

### 6.2 E2301 UseAfterMove (stays, decision 22)

Any use of a name in `M` after the move, on any path, is E2301: read, write, pass to a call, return, store in state, send again, through the name itself, a field read from it, or an alias (the closure). The message: `'x' was moved at line N (arm K) and is used here; after an explicit move the sender's frame may release the value`. The check is flow-sensitive in the let order and per case arm: a move in one arm and a use in another arm is legal; a move before the `case` and a use in any arm is not; a move in an arm and a use after the `case` is not. A move inside a recursive function of the value it will use in the recursive call (`send_then_use_in_recursion` of design §18.6) is a use. Runtime consequence: the emitter may treat an explicitly moved frame value as dead after the send (it does nothing with that today; the frame pops anyway), so E2301 is a lifetime error in the sense of decision 22 even though no release happens before the pop.

### 6.3 E2302 ReferenceAfterRegionGone (stays): the `write_ref` rule and the ref-cell rule (decision 35)

Under full evacuation (§3.3, §4.3) a value that leaves a frame by return, reply, send, spawn or new state is copied, so the only way a pointer into a frame can survive the frame is through a **mutable cell that is older than the frame**. The rule:

> `write_ref(c, v)` is E2302 unless (a) `v`'s type is pointer-free, or (b) `c` is in `F` (the cell was created in this frame, so it dies with the value), or (c) every pointer-carrying part of `v` is older than this frame: `v` is not in `F`.

Condition (c) is where decision 35 lives: a cell reached from `state` (a parameter) is older than the frame; it may be given `state`'s own values, message values that are not in `F` (a message part is older than the frame: it lives in the mailbox buffer until dispatch end, and §4.3 evacuates whatever the kept state reaches), or scalars; it may not be given a value built in this dispatch. A cell in state therefore "takes only values that will be in state" in the sense that every value it can be given is either already old-state or evacuated as part of the new state. The rule is slightly stricter than necessary for the behaviour's own frame (a value built there survives to dispatch end, where evacuation would fix the cell), and that strictness is what keeps the rule uniform across callees: a callee writing its fresh node into a caller's cell is the use-after-pop this code exists for. Message: `the cell 'c' outlives the value 'v' built in this frame (line N); a cell may only be given a value whose lifetime is at least its own`. No new code is needed beside E2302 (§7.5 item 9's question).

The spec's other E2302 reading (a `ref` of a region used after the region was released) has no instance left: regions are released only at frame pops, and a ref cannot be used after its frame has popped except through a cell, which the rule above forbids.

### 6.4 E2300 ReferenceOutlivesRegion (stays, narrowed)

Its earlier condition (a returned, sent or spawned value holding `ref` of L without `region(L)`) describes a case that evacuation now handles safely: a returned `ref?` is copied with its node (H8 is closed by evacuation, not by a rejection). What remains unsafe is a reference that leaves the frame by a path that does **not** copy:

> E2300 is raised when a value holding a `ref`/`ref?`/`buf` into the current frame (a name in `F`) is passed (a) to a foreign parameter the sidecar declares `retains` (§7), or (b) into a `region(L, atomic)` cell shared between actors (Q7; today such cells hold word scalars only, E2316, so (b) is reserved), or (c) as or inside a function value whose captured environment the copier cannot describe (KIND 9 until closure environments are emitted as records, §3.6).

Message for (a): `the buffer 'b' lives in this frame but '<wrapper>' retains its parameter '<p>' past the call; allocate it with alloc_buf_retained (§7)`. The code number and name are kept (decision 16, design §10); the condition is this proposal — Lee to confirm.

### 6.5 E2310, E2311 (type checker, stay)

- **E2310 CrossRegionReference**: `alloc_ref(r, …)` / `alloc_rec` / `alloc_buf` typed with a lifetime other than `r`'s after substitution; and a ref of `L2` stored into a cell of region `L1`, `L1 ≠ L2` (spec §12.4.1 isolation). Unchanged in meaning; the "arena lifetime" exception is gone. For the region-less prims (§3.2) the result lifetime is the annotation's and there is no `r` to compare.
- **E2311 LifetimeConflictAtCall**: stage 1 (Q10, option A) builds one substitution per call in `type_checker_expressions_user_call_check_args_result` and reports a callee lifetime bound to two caller lifetimes. It does not exist today (survey §3) and is a prerequisite of the stdlib change (§8.2: the stdlib's `L` must unify with callers' lifetimes once no region argument carries it). Under the design a lifetime that appears only in a callee's result is a **fresh lifetime of the caller's frame** (the result is evacuated into the caller's frame, §3.3): the substitution binds it to the caller's binding annotation.

### 6.6 `device_window` single owner (decision 24): E2242 DeviceWindowMovedTwice (proposal)

`device_window` stays outside the stack and move-only (spec §4.4.6, H7). The check is the E2301 machinery applied to windows: a window given to `spawn_device`, sent in a message, or stored into a child spec is moved; any later use of it, or of an aggregate holding it, is **E2242** (proposal: the next free number of the device family, whose highest registered code is E2241; the design document's §14.1 row "future device_window single-owner code" takes this number). Two actors can hold one window only by a second move of the same binding, which this catches; `device_window_types_equal_modulo_lifetime` (type_checker_memory_regions.silica:793) is removed so that window lifetimes are compared (H7). Trials: `device_window_used_after_spawn_device`, `device_window_moved_to_worker_then_used`, `device_window_sent_twice` (design §14.1).

### 6.7 Retired codes and the registry

E2303, E2304, E2305, E2306, E2307, E2308, E2309, E2312 are retired (decision 16, 23; design §10) and never emitted; the registry records them as retired with their numbers unused. E2313 to E2318 are unchanged (bounds and atomics; E2315 to E2317 arrive with stage 7). The region meaning of **E2100** moves to E2300 (`type_checker_memory_regions.silica:585`) and `check_sequence_return_lifetime` / `check_ref_lifetimes_covered` (573-601) are **deleted**: their rule (a returned ref must carry its region) is superseded by evacuation. Registry work: E2300 (narrowed condition), E2301, E2302, E2310, E2311, E2321, E2242 and W2300 registered in `error_codes.md` and `error_codes.jsonld`; E2303 to E2309 and E2312 listed as retired.

### 6.8 How lifetime polymorphism (Q10, stage 1) fits

Stage 1 is a prerequisite of §8 and is implemented first (§11.1 phase 1). With implicit per-signature quantification a structure's type `{ root: :none | ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec))), … }` has `L` as a variable of every stdlib function; at a call the caller's annotation supplies the instance. Evacuation makes every lifetime a *frame* lifetime: a value's lifetime is the frame that currently holds it, and it changes at every evacuation (into the caller, into the state area). The type-level `L` therefore no longer names a region's extent; it names **which values must share a lifetime** (isolation: all nodes of one structure have one `L`), and the checker's frame-relative reasoning (§6.1 `F`) supplies the extent. That is why the 9,428 `L` uses in the stdlib need no change (§7.5 item 4): `L` keeps the only job it has left.
## 7. FFI: buffers on the caller's stack, declared retention (decisions 8, 36; §7.5 item 10)

**Buffers for the call.** A `buf(L, S, uint8, N)` passed to a `foreign c_wrapper` function is a frame allocation (§3.2) whose address is passed as today (`ffi_foreign.silica`); the wrapper reads or writes it during the call; the frame pops after. Nothing changes in the ABI (the length word before the elements stays, FFI wrapper spec §6.2). A string argument is marshalled as today (§6.1 of the wrapper spec).

**Declared retention (proposal — Lee to confirm, user-visible in the sidecar).** The sidecar's `wrapper <symbol> { ... }` entry (wrapper spec §3.2, §2.10) gains an optional field naming the parameters the C wrapper keeps past the call:

```
wrapper silica_db_open {
    ...
    retains: [config_buf];
}
```

A parameter named in `retains` must be given a buffer allocated in the dangerous actor's FFI arena (ACB #248/#256/#264, `ffi_arena_runtime_asm.silica:17-70`), spelled at the call site with a new prim **`alloc_buf_retained(n)`** (proposal) whose type is `buf(L, S, uint8, N)` like `alloc_buf`'s and whose effect is `external_danger` (it is legal only inside the dangerous actor's guarded sequence, where the FFI arena exists). The region checker (§6.4, E2300) rejects a frame buffer passed to a retained parameter. The arena is released when the dangerous actor ends (`_silica_rt_ffi_arena_teardown`, unchanged), which is decision 36's lifetime. Undeclared retention is a library bug contained by the guarded region, as decision 36 says; the compiler cannot detect it.

Why the sidecar and not the Silica declaration: the fact belongs to the C wrapper, is written by the wrapper's author, and the sidecar already carries the per-wrapper metadata the compiler reads (`ffi_sidecar_loader`); the `foreign` declaration in Silica stays a signature. The alternative, a parameter marker in the `foreign … fn` line, is listed in §12.

**Wrapper specification entries to add:** §3.2 (the `retains` field and its validation: every name must be a parameter of the wrapper, of buffer or pointer type); §6.2 (a retained buffer lives in the FFI arena, released at actor end; a non-retained buffer is valid for the call only); §7.5 (actor-local containment: the FFI arena is the one place a foreign pointer may legitimately outlive a call).

## 8. Standard library: field removal, frame allocation, result reshaping, persistence (decisions 13, 37; §7.5 item 12)

### 8.1 The family-arena field, every site

From the 2026-10-24 survey of `compiler/stdlib/data_structures/` (53 `.silica` files):

| Family | File | `canonical_arena_lookup` site (key) | Constructor | Node allocation helper |
| --- | --- | --- | --- | --- |
| weight-balanced map | `wbt_map.silica:53` (1) | `empty_map` (37); binding `ph: region(L, normal)` | `alloc_rec(arena, (key, value, size, left, right))` at :180, `arena <- tree.region` at :207; `alloc_ref(map.region, …)` :7341; `alloc_buf(map.region, n)` :7247; `ref_in_region(node_ref, map.region)` :7953 |
| weight-balanced set | `wbt_set.silica:47` (1) | `empty_set` (36); `ph:` | one `alloc_rec`, one `alloc_ref`, one `alloc_buf` |
| Brodal–Okasaki heap | `brodal_okasaki.silica:88` (82) | `empty_heap` (74); `arena:` | `brodal_okasaki_node.silica:38` `alloc_rec(arena, (item, child_count, :none, kids))` |
| skew random-access list | `skew_ral.silica:69` (81) | `empty_ral` (56) | `skew_ral_node.silica` one `alloc_rec` |
| binary tree | `tree_binary.silica:274` (83) | `empty_tree` (264) | one `alloc_rec` |
| rose tree | `tree_rose.silica:413` (85) | `with_root` (401) | one `alloc_rec` |
| WBT graphs | `graph_wbt_directed.silica:205`, `graph_wbt_undirected.silica:200`, `graph_weighted.silica:245`, `graph_weighted_undirected.silica:239` (all 90) | `empty` | nodes through `wbt_map`/`wbt_set` |
| CSR snapshot | `graph_csr_core.silica:789` (91) | `freeze` (786) | four `alloc_buf(arena, …)` at :793-796 |
| dense matrix graph | `graph_dense_core.silica` | (through its slot map) | one `alloc_rec` |

The field is spelled `region:` (1,151 occurrences), `arena:` (24) and `ph:` (2); 52 of the 53 files mention `region(L` in a record type (only `skew_ral_weights.silica` does not); the ten trait files (`OrderedMap`, `OrderedSet`, `SearchTree`, `Heap`, `PriorityQueue`, `Tree`, `BinaryTree`, `DirectedGraph`, `UndirectedGraph`, `WeightedGraph`) carry it in their inline types too. About 138 lines read `.region` (mostly `region: x.region,` copies in result records; wbt_set 29, tree_binary 18, wbt_map 13). The 25 compiler modules that use stdlib structures (design §1.4) spell the same inline record types with the field.

**The change (chunk 4 stage 2 as redefined):** remove the field from every record type in those files and from the compiler's 25 modules; delete the 11 `canonical_arena_lookup` bindings; replace `alloc_rec(arena, …)`, `alloc_ref(map.region, …)`, `alloc_buf(arena, …)` by the region-less forms (§3.2); delete `ref_in_region(…, map.region)` and the `arena: region(L, normal) <- tree.region;` lets; drop the `region: x.region,` field copies. It is a source edit of record-type spellings and nine allocation sites, verified with `git diff` per file (memory note "Regex masking corrupts literals"), not a rename script. Interface files regenerate with the build.

### 8.2 Allocation in the frame and the logging updaters

After the edit every node is allocated in the frame of the updater that builds it (§3.1) and reaches the caller by return (adoption or evacuation, §3.3). The update functions' recursion is the classic path copy: `insert(node, k, v)` recurses to the leaf and rebuilds the path on the way up; each level's `alloc_rec` is in return position of that level, so the whole path is adopted frame by frame and evacuated once by the consumer, O(path) copies. Rotations allocate two or three nodes in return position likewise. `meld` of two Brodal–Okasaki heaps allocates its new root and link nodes the same way; its constant-time bound within a family held because both heaps' nodes were in one arena, and it still holds: the melded heap references the two inputs' nodes wherever they are (frames, the state area, a mailbox buffer), and only the new nodes are built.

**Retire sites.** Each family's node helper gets the replacing form (§4.2): `wbt_map`/`wbt_set` (`make_node` with the old node: the path-copy call sites, the rotation helpers, `delete`'s removed node), `brodal_okasaki_node` (`link` retires the two roots it links under a new one; `pop` retires the popped root), `skew_ral_node` (update along the index path), `tree_binary`, `tree_rose` (replace and clear paths; `remove_child` retires the removed slot node), `graph_dense_core` (slot map updates), `graph_csr_core` (`freeze` builds buffers from a WBT graph and retires nothing: a snapshot is a new value). The graph facades update through `wbt_map`/`wbt_set` and inherit their retires; §13 item 1 states the no-inner-sharing condition the WBT graph families must keep (an adjacency set is stored under one vertex only).

**Signatures.** No change to the 9,428 `L` uses (§6.8). Every constructor's result type keeps its `L`; with no region argument, a call `m: { root: … ref?(L1, …) …} <- wbt_map@empty_map()` binds the callee's `L` to `L1` through the result (stage 1 substitution, §6.5).

### 8.3 Change-result reshaping in the same pass (decision 37)

Design §3.14's result sums replace the flag records at the same time, because both edits touch every updater's return record. The survey counted 433 lines of `inserted:` / `replaced:` / `removed:` / `updated:` / `appended:` / `changed:` / `added:` / `compatible:` fields across 26 files (wbt_map 101, wbt_set 70, tree_rose 46, tree_binary 41, the graph facades 7 to 22 each). Each updater's result becomes the design §3.14 sum (`:unchanged | (:inserted, V) | (:replaced, V)` and the rest of that table), a no-op returns `:unchanged` and allocates nothing (so it retires nothing, §4.2), and the ~300 trial sites and 55 compiler sites that read `.inserted` (design §3.14) become `case` arms. The reshaped sums are what the use analysis reads to name versions (§4.1: the arm binding of `(:inserted, m2)` is the version name). `common_contract.md` §6 and §7 change accordingly (§11.6).

### 8.4 Persistence on the stack

R2 and R3 hold because: a change builds new nodes and points them at the unchanged old nodes, wherever those are (an older frame, the state area, a mailbox buffer); it never writes an old node; the old root stays valid in its frame or in the state area until that frame pops or the state slot is released by a proven chain. Within one dispatch any number of versions coexist; across dispatches, versions that reach the new state are evacuated with sharing preserved (forwarding), and versions that do not are garbage at the pop. The 149 trial updater calls that reuse old versions (design §0) are legal as long as the old version is used within its frame's life, which is every case they test. What is **not** preserved is sharing *across* two state slots and *across* actors: the first by the field-wise copies of §4.4 and §5.4 (duplicated, §13 item 1), the second by copy-on-send (decision 38).
## 9. Removal of the implicit heap and the family arenas, site by site

Requirements §8.2's inventory was re-run for this document (2026-10-24, `grep` of `_silica_rt_region_alloc` call lines over the four emitter trees, comments excluded). It matches §8.2 exactly for apple_silicon_mac (22 calls, definition at 3683/3685, the malloc stub at prims_list.silica:803) and linux_aarch64 (22 calls, definition 3721/3723); linux_x86_64 shows the 20 calls of §8.2 plus the definition-adjacent lines in `prims_actors_runtime_asm_b.silica` (125, 805, 1000-1017, 1115); the ESP32-S3 shows its 5 lines, where `silica_rt_region_alloc` is `.set` to `silica_rt_alloc` (`rt_heap.S:179-180`). Every site and its replacement:

### 9.1 Emitted code (per target; the Linux twins have the same sites at the lines §8.2 lists)

| Site (apple_silicon_mac) | Serves | Replacement |
| --- | --- | --- |
| `terms/term_aggregate_helpers.silica:703` (`aggregate_return_heap_promote_x0_copy`, used by `arg_aggregate_heap_promote` 551, `tuple_elem_heap_promote` 565, `tuple_elem_sret_reclaim` 538, `tuple_elem_frame_var_promote` 580, `frame_var_arg_promote` 606, `let_early_heap_promote_asm` 679) | every promotion of a frame aggregate to the heap | **deleted**. A frame aggregate passed by name or packed into a tuple stays where it is: the callee's frame is below and the value is older (safe); a value packed into a result is evacuated or adopted with the result (§3.3). H3's fix (`frame_var_arg_promote`) is no longer needed because a callee cannot outlive the caller's frame value except by return, which evacuates. `tuple_elem_sret_reclaim`'s slab accounting becomes a frame allocation of the element (§3.1). |
| `terms/prims/prims_actors.silica:305` (`heap_promote_stack_aggregate_x0`: spawn init state, state move) | spawn initial state copy, state shell copy | spawn: §5.4 (copy into the child's base); state: §4.3 (`bmv_state_asm` / `bmv_state_reuse_asm` deleted) |
| `prims_actors.silica:637` (`bmv_state_reuse_asm`, the tagged fresh block) | state reuse in place | **deleted** (§4.6) |
| `prims_actors.silica:563` (`heap_promote_reply_x0`, `_silica_rt_region_alloc_in` into the caller's arena) | the H4 reply copy | §5.3 (copy into the caller's stack) |
| `terms/prims/prims_checked_int64.silica:72` (`emit_checked_pair_from_regs`) | the `(ok, value)` pair | a 16-byte frame allocation (§3.7) |
| `terms/prims/prims_list.silica:447` (`emit_list_head_box`), `659`, `675`, `690` (`L_list_prepend_helper`: handle, cow chunk, new chunk), `725`, `760`, `770` (`L_list_tail_helper` and the length/at paths that allocate a handle) | list handles and chunks | caller-provided frame blocks (§3.7) |
| `prims_list.silica:803` (`emit_region_alloc_stub`, the malloc forwarder with `_silica_rt_region_list`, `_silica_rt_region_mark`, `_silica_rt_region_release_to`) | programs without the actor runtime | **deleted** with the heap; the dead `mark`/`release_to` scope release goes with it (design §1.2) |
| `terms/term_message_copy.silica:936` (`L_mc_alloc_shell`: `_silica_rt_region_alloc` / `_silica_rt_region_alloc_in`), `927` (`L_mc_new_region`: `_silica_rt_raw_alloc`), `922` (`L_mc_is_canonical`) | the copy's shell and fresh regions | the destination cursor into the mailbox buffer, the caller's stack or the child's base (§5.1); the three helpers are deleted |
| `terms/prims/prims_memory.silica:139` (`emit_alloc_region`: `_silica_rt_raw_alloc(4128)`), `181-185` (`emit_region_bump_check`), `576-580` (`L_region_grow`), `118-131` (`emit_canonical_arena_lookup`, `_same`), `113` (`emit_ref_in_region`) | region prims | §3.2: witness word, frame allocations; `L_region_grow`, the canonical prims and `ref_in_region` deleted |
| `emitter_core.silica:2363`, `3322`; `terms/term_reg_spill.silica:735-736`; `prims_actors.silica:1049` (`timer_thunk_destroy_lines`) (`_silica_rt_region_destroy` calls: `fn_destroys_region_param`, `let_owns_local_region`, the message-record region release, timer thunk regions) | the owned-region release heuristics | **deleted**: a region owns no memory (§3.2). `fn_destroys_region_param` (2426) and `region_param_index`/`return_type_carries_region` go, which also removes the TCO disablement they caused (`tco_eligible` 1679's `msg_drop` and region arguments) |
| `terms/term_message_regions.silica` (whole module, `fn_message_region_offsets`) | dispatch-scoped region release (SD-7 first form) | **deleted**; the mailbox buffer release of §5.1 replaces it; `type_is_pointer_free` moves to `term_message_copy` where §4.1's analysis also needs it |
| `terms/term_emit_kind_compound_part2.silica:245-269` (`alloc_region` / `canonical_arena_lookup` prim dispatch) | prim emission | `alloc_region` → witness; the canonical arm removed |
| `terms/string_concat_mmap_nomte.silica:48-76` (`L_sc_bump_alloc`, arena, lock, mark/release) and the other `*_mmap_nomte` string helpers that allocate | strings | §3.7 (two-call helper, frame allocation); the lock and arena deleted |
| `terms/canonical_arena_runtime_asm.silica` (whole module, `_silica_rt_canonical_arena_table`, `_silica_rt_canonical_arena_count`, `_silica_rt_region_lock`) | family arenas, H1's lock | **deleted**; `_silica_rt_region_lock` has no remaining user once `L_region_grow` is gone |
| `terms/prims/prims_actors_runtime_asm.silica:3440-3504` (`_silica_rt_actor_init_region`, `_silica_rt_actor_dealloc_region`), `3669-3760` (`_silica_rt_region_alloc`, `_in`, the 64 MB chain, the `main` fallback list), `3811` (`_silica_rt_raw_alloc`), `3830-3842` (`_silica_rt_region_destroy`), ACB #160..#184 | the implicit heap | **deleted**; `_silica_rt_raw_alloc`/`free` stay only if the FFI arena or the registry use them (they use `mmap`/`malloc` directly today, `ffi_arena_runtime_asm.silica:36-53`) |
| `prims_actors_runtime_asm.silica:1731` (`get_cpu_topology` core list), `2795`/`2809` (`_silica_rt_build_int_range_list`), `2863`/`2876` (`_silica_rt_build_list_from_words`), `2940` (`_silica_rt_cstr_to_string`) | runtime-built lists and strings returned to user code | these runtime routines build values **in the calling actor's frame**: each takes a destination block the emitted call site allocates after a sizing call (`_silica_rt_int_range_list_bytes(n)` etc.), the pattern of §3.7's two-call string helper; `get_actor_memory_usage`'s 40-byte record (board `6157-6199`, hosted `1078`) is built in the caller's X8 slot (it is a static record) |
| `terms/prims/prims_actors_child_table_asm.silica:1652`, `1679` (`get_child_info` record), `1865`, `1879`, `1899` (`which_children` records, chunk, handle) | supervisor query replies | built in the replying supervisor's frame through the same sizing-then-destination pattern; they are replies and are copied to the caller by §5.3 |
| `ESP32-S3_raw/terms/*` (5 call lines: `term_aggregate_helpers.silica:679`, `term_message_copy.silica:946`, `prims/prims_actors.silica:313`, `prims/prims_checked_int64.silica:73`, `prims/prims_list.silica:449`) and the heap-promote helpers at `prims_actors.silica:291-313, 452, 560, 582, 701` | the same roles on the board | the same replacements through the Xtensa helpers (`xt_isa`, `xt_mem`); the board's `function_prologue` limit check is reused for dynamic allocations (§3.2) |

### 9.2 The front end

| Site | Replacement |
| --- | --- |
| `sir_generator/terms/collection_constructor_calls.silica:234` (`build_region_prim_from_sir("canonical_arena_lookup", …)` synthesised for collection constructor lets; comment at 58-60) | the constructor let no longer binds a region; the synthesised prim is removed and the constructor call is lowered as an ordinary call |
| `sir_generator/terms/memory_region_calls.silica:36, 149, 185-188`; `terms_region_lowering.silica:31-148`; `effect_checker/effect_checker_memory_regions.silica:160, 253, 283`; `type_checker/expressions/type_checker_expressions_region_builtins.silica:231-300`; `type_checker_memory_regions.silica` | the builtin lists naming `canonical_arena_lookup`, `canonical_arena_same`, `ref_in_region` | removed from the lists; the region-less `alloc_*` forms (§3.2) and `retire` (§4.2), `alloc_buf_retained` (§7) added with their result typing (annotation-driven) and effects |
| `type_checker/expressions/type_checker_expressions_bindings.silica:155-162` (`"moved_region"` rebinding at spawn) | removed; E2301 covers an explicit `move` of a spawn state (§6.2) |
| `type_checker_memory_regions.silica:573-601` (Phase A `check_sequence_return_lifetime`, E2100 region meaning) | removed (§6.7) |

### 9.3 The ESP32-S3 runtime

| Site | Replacement |
| --- | --- |
| `rt_heap.S:179-180` (`silica_rt_region_alloc` / `silica_rt_raw_alloc` aliases of `silica_rt_alloc`) | the emitted code no longer calls them; the aliases are removed; `silica_rt_alloc` stays for the runtime's own blocks (nodes, buffers, chunks) |
| `rt_heap.S:289-370` (`silica_rt_region_destroy`, `silica_rt_region_grow`, `silica_rt_region_lock`) | deleted with the region blocks |
| `rt_heap.S:452-531` (`silica_rt_state_release`, `silica_rt_heap_is_block`, **`silica_rt_heap_reaches`** depth-4 reachability) and `rt_actors.S:2564-2570, 1043-1059` (`ACB_STATE_OWNED`, `silica_rt_state_adopt`, `_adopt_ref`), `rt_supervisors.S:671-754` (`silica_rt_init_owners_reach`) | **deleted**. `heap_reaches` is a bounded reachability scan deciding at run time whether to free: the kind of mechanism decision 4 excludes. The state chain (§2.6) and the compile-time proof replace it. |
| `rt_ordering.S:19-46, 90-191` (the board's `silica_rt_canonical_arena_lookup` / `_same` twins) | deleted with the hosted canonical module |
| `rt_actors.S:2625-2680` (`silica_rt_run_behaviour`: copies the returned state into `ACB_STATE`) | stores the evacuated root (§4.3's board pass) |
| `rt_actors.S:2582-2583`, `1025-1035` (`silica_rt_node_release_payload`, `MSG_PAYLOAD_OWNED`) | the payload block is the mailbox buffer: freed at dispatch end unless forwarded (§5.1); at the end-of-actor drain |

### 9.4 What the removal measures

The zero-growth trials of design §19.4 (`actors_addition/zero_heap_growth_*`, `stack_budget_board_addition/*_frees_heap`) measure heap growth; under the design the measure is **stack depth and state-area size across a long run** (`get_actor_memory_usage` committed and high-water, and `#568` through a runtime probe), and each case of design §19.2 gets one such trial (§11.3).
## 10. Error handling: `(:explicit, :stack_exhausted)` (decision 26, Q9; §7.5 item 6)

**Update 2026-10-24 (decision 39, supersedes the `:stack_exhausted` wording in this section and in P11).** Stacks grow, so "stack exhausted" is the wrong name. The reasons are split by cause. `(:explicit, :reservation_exceeded)`: an actor outgrows a reservation its spawn lowered. `(:explicit, :out_of_memory)`: the default reservation (machine memory plus swap) or, on the board, the memory budget runs out. `(:explicit, :state_too_large)`: the spawner finds that a child's initial state is bigger than the child's reservation (P11: the spawner fails). `(:explicit, :stack_reserve_failed)` keeps its name (Lee, 2026-10-24): it stays the reason when a stack reservation could not be made at spawn. Read each `:stack_exhausted` below by its row: a lowered reservation is `:reservation_exceeded`; the default reservation or the board budget is `:out_of_memory`; the spawn row is `:state_too_large`. **Today:** the runtime raises `:stack_exhausted` (guard hit) and `:stack_reserve_failed`, and `build_runtime_atom_table` appends both to the reason-line atom table. **Plan:** the atoms, the table entries and the goldens that name them change in phase 0 (§11.1: `actor_stacks_addition`, `carriers_addition/workers_exhaustion_on_one_carrier_keeps_siblings`, `stack_budget_board_addition` and every golden that carries the atom table); a trial `error_enforcement_addition/spawn_state_too_large` joins the phase-3 gate.

**Registration.** Nothing new to register: `_silica_rt_stack_exhausted_atom` exists (`prims_actors_stack_asm.silica:93`), the fault handler already turns `_silica_rt_stack_grow_to`'s return 1 into `_silica_rt_actor_fail_current(acb, :stack_exhausted)` for a lowered reservation (spec §15.1.2.2, trials `error_enforcement_addition/stack_policy_*`), and the board raises it through its guard-band store (`rt_actors.S:1717-1721`). What changes is **where** the limit can be reached:

| Path | Today | Under the design |
| --- | --- | --- |
| frame growth (a deep call) | fault → grow → exhausted → actor fails | unchanged |
| a dynamic allocation in a frame (§3.2) | — | the same fault path: the `SUB SP` itself does not fault, the first store into the new node does, inside emitted code with SP inside the reservation, which is the case the handler already recognises |
| scratch for an evacuation (§2.5, §3.5, §4.3) | — | the same fault path, with SP still inside the reservation (the runtime routines run on the actor's stack); a fault inside `_silica_rt_evacuate` is recognised by address, not by code range |
| edge extension at dispatch end (§4.3) | — | writes into committed memory (the extension lies within this dispatch's frame span, which was committed); cannot fault |
| the fallback copy (§4.4) | — | its scratch (about the state's size) may fault-grow: same path; failure ends the actor **before** the old state is overwritten (pass 1 is to scratch), so a supervisor restart starts from the spec's state, never from a half-copied one |
| a reply copied into the caller (§5.3) | — | the **replier** calls `_silica_rt_stack_grow_to(caller_acb, dest)` explicitly; on 1 it sets `reply_set = 4` and the **caller** fails with `(:explicit, :stack_exhausted)` when it wakes (the caller's reservation is the one that is too small); the replier is unaffected. For `main` as caller (no reservation) an overflow is a fatal fault, status 70, as spec §15.1.2.2 says for `main`'s stack |
| spawn / restart state into the child's base (§5.4) | — | the spawner calls `_silica_rt_stack_grow_to(child_acb, …)`; on 1 the spawn fails as a reservation that cannot hold its state: the spawner gets `(:explicit, :stack_reserve_failed)`-style failure? **No**: decision 26 names `:stack_exhausted` for "hitting the limit during an allocation or evacuation"; the spawner is the actor doing the allocation, so the **spawner** fails with `(:explicit, :stack_exhausted)` (proposal — Lee to confirm; the alternative is to fail the child before its first dispatch) **[confirmed by Lee 2026-10-24 with the reason `(:explicit, :state_too_large)`, decision 39]** |
| ESP32-S3: state chain growth under a lowered reserve | — | `silica_rt_chunk_next` returns −1 when `MCHAIN + ACHAIN + SCHAIN` bytes would exceed the reserve; the actor ends with `:stack_exhausted` (the existing path) [2026-10-24, decision 39: `:reservation_exceeded` for a lowered reserve, `:out_of_memory` when the board memory budget runs out]; under the default reserve a failed heap take is the runtime abort 71 (as for stacks today) |

**Supervisor's view.** The reason is reported like every `(:explicit, atom)` (tag 4, failure reporting `runtime_failure_reporting.md`); the supervisor restarts the child from the row spec buffer (§5.4) if its strategy says so. A child whose steady-state **state area** does not fit its lowered reservation will fail at every restart: the trial `state_exceeds_lowered_reservation` (§11.3) shows the supervisor's `:max_restarts` ending the loop, which is the documented outcome for a reservation the program chose too small.

**Default reservation.** With the default (machine plus swap) none of these can be reached before the host's memory is exhausted, and that outcome stays the host's (spec §15.1.2.2 "Memory Exhaustion"; `:oom` is not a failure reason).
## 11. Implementation plan, trials, specification changes, risks and costs

### 11.1 Phases

**Gate between phases (Lee, 2026-10-24).** There are **no fixed points between phases**. Exactly one fixed point is reached, after the last phase, on every hosted target. **[Lee, 2026-10-24, second ruling: the last phase is the ESP32-S3 phase 9; the single hosted fixed point is phase 10 and comes after the board phase, run last on the Mac, pix and nix.]** Between phases the gate is: the compiler builds (the incremental development build, `make INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in `compiler/src`, with the published compiler as the builder) and the trials stay green on the targets the phase touches (`make integrate`, memory note "Trials: integrate is the gate"). No phase's completion depends on a gen1/gen2/fixpoint run. Each phase names a **smoke test** that stands in for the fixed point it does not run (§11.4).

**Bootstrap rule** (design §13): a language change the compiler's own source uses must be accepted by the published compiler that builds it; so every phase that changes the language lands as implement-then-use, and the compiler's own source adopts a new form only after a compiler that accepts it has been built and used as the builder for the next step (an unpublished build in the scratchpad is enough for development; publishing is Lee's).

**Target order.** Apple Silicon leads each phase; Linux AArch64 and Linux x86-64 take the same phase as a port of the diff (the three hosted emitter trees are twins; the x86 twin through its `x86_isa`/`x86_mem` helpers) before the next phase starts on the Mac, so the trees never diverge by more than one phase; the ESP32-S3 takes phases 0 to 8 together after the hosted phases, as its own board release. **[2026-10-24: the board phase 9 comes before the fixed point (phase 10); the board release uses a cross compiler built from the final sources.]**

| Phase | Changes | Language change? | Stays working / gate | Smoke test |
| --- | --- | --- | --- | --- |
| **0. Groundwork** | **the failure-reason atoms of decision 39 (`:reservation_exceeded`, `:out_of_memory`, `:state_too_large`; `:stack_reserve_failed` keeps its name; `:stack_exhausted` is replaced in the runtime and in the reason-line atom table that `build_runtime_atom_table` appends), done here because the atom table is in every golden that phase 0 refreshes;** ACB growth (§2.2) and the state-area header; `_silica_rt_stack_measure` / `_release_to` measuring from the edge with `edge = top - 1040` (no behaviour change yet); descriptors for LIST, STRING, CLOSURE kinds and per-type descriptor labels (§3.6), `L_mc_measure` (§5.1); the string literal marker `-2`; **Q19 enforcement** (unbound `rec` is E2010 everywhere) **after** the stdlib and the compiler's 25 modules spell their node shapes (that rewrite is the first commit of the phase, built by the published compiler which accepts both spellings) | yes (Q19: rejects what it accepted) | every suite green on the Mac; the `.ascomp` goldens of every unit change (frame layout, new descriptors) and are refreshed under Lee's rule (`.sout` = `.scout`); the atom-table change also touches the goldens that name the old reasons, among them `actor_stacks_addition`, `carriers_addition/workers_exhaustion_on_one_carrier_keeps_siblings` and `stack_budget_board_addition` | build the compiler's heaviest units (`emitter_core`, `type_checker_expressions_*`, `wbt_map`) with the phase-0 compiler; compare peak RSS with the 2026-10 numbers (memory note "Emitter core 4 GB campaign") |
| **1. Lifetime polymorphism (Q10, stage 1)** | per-call lifetime substitution in `type_checker_expressions_user_call_check_args_result`, E2311, removal of the binder fallback (`expected_lifetime_is_binder`) and of `device_window_types_equal_modulo_lifetime` (H7) | yes, relaxing | `generic_lifetime_name` passes; the `L1` workaround comments leave the trials | typecheck the stdlib and the compiler with it (they only use `L`, so nothing moves) |
| **2. Frame allocation and evacuation on return** | §3.1–§3.7: the frame allocation helper per target; `alloc_*` as frame allocations with the witness `alloc_region`; the region-less `alloc_*` forms; the return-position analysis and `\|rp` in the SIR; frame adoption in the emitter (callers restore SP after non-adopting calls); `_silica_rt_evacuate`; strings, lists, checked pairs in frames; every promote helper, `L_region_grow`, the string arena, the `_silica_rt_region_destroy` heuristics and `term_message_regions` removed; **the implicit heap routines stay** in this phase for the runtime's own lists/strings and for state/messages (phases 3, 4) | yes (region-less `alloc_*`; `ref_in_region` retired) | `memory_region_addition`, `list_addition`, `string_addition`, `records_addition`, `tuples_addition`, `functions_addition`, `recursive_function_addition`, `deep_frame_spill_addition`, `codegen_regressions`, `ordered_data_structures` green on the Mac (the stdlib still uses its arena field: it allocates through `alloc_rec(arena, …)` whose arena argument is now ignored and whose nodes are frame-allocated, which is already the new model for nodes) | the compiler compiles itself unit by unit with the phase-2 compiler (no gen2 comparison): the `.sams` of each unit assembles and links, and the resulting binary compiles `trials/base`; peak RSS per unit recorded |
| **3. State at the base, dispatch end, retire** | **`state_policy(…)` and `compact_state()` (§4.7, §5.4): the compiler first accepts the argument as optional, then a script adds `state_policy(:keep_state_area)` to every spawn site in the compiler's own source (the pipeline actor and the other spawns in `compiler/src`), the stdlib and `trials/` (several hundred sites: `spawn` alone is about 700 in `actors_addition`, `supervisors_addition` and `ffi_addition`; the script is Opus's, the run and the `git diff` verification Sonnet's, memory note "Regex masking corrupts literals"), and the optional form is removed in the same phase so the argument is required (bootstrap rule: implement, then use);** §2.3, §4: free lists, `retire`, the release log, the per-behaviour analysis, W2300/E2321 and strict mode, `_silica_rt_state_evacuate` and `_silica_rt_state_copy_all`, the new dispatch-end order, the behaviour prologue flag; `bmv_state_*` and the tagged block removed | yes (`retire`, W2300, E2321, `strict state_release;`) | `actors_addition`, `supervisors_addition`, `actor_stacks_addition`, `carriers_addition`, `record_shapes_actors_addition`, `timers_addition` green; every actor trial's state now lives at its base | the compiler's pipeline actor (`main.silica` spawns it) runs every unit as one dispatch: its state is small, so this measures the dispatch-end path at scale once per unit; compile the compiler's units with it |
| **4. Messages, replies, spawn** | §5: the mailbox buffer with exact sizing, KIND 7 copies, the end-of-actor drain, forwarding-only `\|_mvs`, `\|_mvr` removed, replies into the caller's stack with the extended call record, spawn and restart into the child's base (the row spec buffer), `move(x)` as copy; the runtime's list/string builders rewritten to destination blocks; **the implicit heap and `_silica_rt_region_alloc` deleted** on the hosted targets | no new syntax (`move` exists) | `actors_addition`, `supervisors_*`, `bees_regions_addition`, `ffi_addition`, `region_hazards_open_addition` (its staged trials now pass or are promoted), `cpu_discovery_and_spawn_pinning`, `scheduler_policy_addition` | the compiler under the phase-4 compiler: the per-unit process loop is a spawn + call + reply per unit, which exercises §5.3 and §5.4 hundreds of times per build |
| **5. Stdlib field removal and result reshaping (chunk 4 stage 2 + decision 37)** | §8: the field removed from 52 files and the 25 compiler modules, the 11 constructor sites, `retire` in the updaters (logging updaters), the result sums of design §3.14, the ~300 trial sites and 55 compiler sites rewritten to `case`; `canonical_arena_*` removed from the four runtimes and the front end (§9.2) | yes (stdlib API: result sums) | `ordered_data_structures` (goldens re-derived: the result shapes change the printed output of trials that print flags), `generic_modules_addition`, `traits_addition`, `compiler_addition`; the compiler's own uses of `wbt_map` (`compiler_maps`, the atom tables) rewritten first with the phase-4 compiler as builder | the compiler built by itself once more, unit by unit; `four_actors_same_family_inserts` (H1) now shows no shared allocator |
| **6. Region checker (report, then errors)** | §6: `region_checker/` report-only behind `strict region_check;`; E2300 (narrowed), E2301, E2302 with the `write_ref` rule, E2242; E2100's region meaning removed; then errors on by default; registry updated | yes (errors on) | report mode over the stdlib, the compiler and `trials/` shows only real misuse (each becomes an error trial) or checker defects (fixed) before errors are switched on; `error_enforcement_addition` and the new `compile_defects_*` suites green | the compiler's own source passes the checker clean (it must, to build itself) |
| **7. FFI retention** | §7: `retains:` in the sidecar, `alloc_buf_retained`, E2300 case (a) | yes | `ffi_addition` with the new wrapper fixtures (memory note "FFI fixture symlink trap": `ln -sfn`) | the compiler's own `device_io` and file wrappers declare no retention; the `dangerous_*` trial libraries do |
| **8. Linux lock-step close-out** (the fixed point moved to phase 10, Lee 2026-10-24) | the two Linux trees carry phases 0–7 (they have followed phase by phase); `.linux_*.ascomp` goldens captured on pix and nix; ~~**then** `make fixpoint` on the Mac, pix and nix: gen2 compiles the whole tree, gen3 == gen2~~ (moved to phase 10) | no | `make integrate` green on the three hosts (~~gen3 byte-identical to gen2 on each~~, now phase 10) | the compiler's heaviest units built with the phase-8 compiler on the three hosts, as in the earlier phases |
| **9. ESP32-S3** | §2.6 (state chain, ACB 160 B, one-pass evacuation, chunk scratch), §9.3 removals, board twins of phases 0–7, the board trials of §11.3, Lee's board runs | as above | board suites green from the cross compiler built from the final sources by the phase-8 development compiler (~~by the fixed-point Mac compiler~~: the fixed point now follows, in phase 10) | the 1,000-actor trial with state at the base (budget plan item F's gate) |
| **10. The single fixed point** (Lee, 2026-10-24: after the board phase) | `make fixpoint` on the Mac, pix and nix with the final sources: gen2 compiles the whole tree, gen3 == gen2; the board release is rebuilt from the same sources and its suites re-run if the fixed-point compiler's output differs from the phase-9 cross compiler's | no | `make integrate` green on the three hosts; gen3 byte-identical to gen2 on each | this **is** the fixed point |

Phases 2 to 5 are the large ones and are Fable's; builds, trial runs, golden refreshes and the Linux captures are the lesser models' (per the Fable-use rules); trial sources are Opus's; the specification text is Sonnet's from §11.6.

### 11.2 Risks of deferring the fixed point, and how the phases reduce them without one

| Risk | Why it is real | Reduction without a fixed point |
| --- | --- | --- |
| Self-hosting defects surface only at the end: a construct the compiler's own source uses that the new model miscompiles (an aggregate returned through three frames, a string built in a loop of 10⁵ concats, a `wbt_map` of 60,000 atoms in the state of the pipeline actor) | the compiler is the largest Silica program and the only one that exercises every emitter path; today's trials cover far less | every phase's smoke test compiles the compiler's **heaviest units with the new compiler** and runs the result on `trials/base` (a one-generation test: no gen2 comparison, but a crash, a wrong `.sams` or a 40 GB RSS shows at once); the `.sams` of a unit built by the old and the new compiler are diffed for unexpected differences in phases 0 and 1, where the generated code is expected to change little |
| Memory peaks of the compiler's own units under frame evacuation (the emitter builds a unit's assembly as one string through deep returns; `type_checker_callee_env` rebuilds per call site) | memory note "Emitter core 4 GB campaign": the units peak 6–8 GB on 16 GB machines today; a return-path copy of a 100 MB string at each of d levels would be fatal | phase 2's return-position analysis makes `concat` in tail position adopt, not copy (§3.3); the phase-2 smoke test records peak RSS per unit and any unit above its 2026-10 peak is root-caused before phase 3; a unit that must bind a huge string and use it (not return it) is rewritten to pass it on (a source fix, allowed because it is not a workaround for a defect but the idiom the model asks for) |
| Performance of evacuation and copies in the trial tree: the `_addition` suites are the serial cost (memory note "Silica CI trial cost") | two copies per consumer-bound result, a measure+copy per send | phase 2 and phase 4 time `make integrate` before and after; a suite that doubles is examined; the forwarding-only elision and adoption are the levers, both already in the design |
| The Q19 rewrite (phase 0) inflates the inline types of the compiler's 25 modules and the stdlib signatures: `root: ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec)))` in every atom-table signature | memory note "Type-check parse_type memo": type-checking the type checker already re-parses giant repeated inline types; the type surface cache and interner memo are the mitigation | measure the type-check time and RSS of `type_checker_expressions_*` after the rewrite in phase 0 before anything else; if it regresses, extend the surface memo (a compiler change, not a design change) |
| Divergence of the three hosted trees | each phase is a port of a diff | the Linux port of each phase lands before the next Mac phase begins; a `diff` of the three emitter trees' changed functions is part of each phase's hand-off |
| A checker rule the compiler's own source trips (phase 6) | the bootstrap rule | report mode first (phase 6a) over the compiler's own source; errors only after it is clean |
| Behaviour-changing readings in this document that Lee has not confirmed (§12) | implementation on a wrong reading is rework | §12 is settled before phase 2 starts; §13 before phase 3 |

### 11.3 Trials to add (named; one per rule)

Each goes in the suite named, or in its own `compile_defects_<slug>_addition` when a published compiler rejects it (memory note "Compile-defect trials need their own directory"). Goldens are derived from real output.

| Rule | Trial | Shows |
| --- | --- | --- |
| decision 2, R4.3 | `memory_region_addition/return_evacuates_new_nodes` | a function builds a 1,000-node version in its frame and returns it; the caller validates it after the callee's frame is reused by another call |
| §3.3 adoption | `recursive_function_addition/map_return_position_linear` | a non-tail `map` over 10⁵ elements; wall time and `high_water` grow linearly (the quadratic evacuate-per-level does not happen) |
| §3.3 evacuation at the consumer | `memory_region_addition/bound_result_evacuated_once` | a bound update result used twice; the allocator probe counts one evacuation |
| decision 29 | `string_addition/concat_in_frame_released_at_pop`, `string_addition/literal_never_copied` | a 10⁵-concat loop in a called function; `committed` returns to the baseline after the call; a literal's address is stable across a send |
| decision 30 | `actors_addition/list_copied_on_send_sender_pops` | the sender casts a list and returns, its frame is reused; the receiver reads the list intact; `prepend` by the receiver does not disturb the sender's list |
| decisions 3, 14 | `actors_addition/state_at_base_survives_release_on_return` | `:release_on_return` actor with a 10⁴-node map state, 10⁴ messages; state intact, `committed` equals the state size between messages |
| decision 27 | `actor_stacks_addition/stack_policy_measures_from_edge` (×5 algorithms) | each algorithm's retained bytes exclude the state area; the state is never decommitted |
| decision 40 | `actor_stacks_addition/state_policy_keep_state_area_holds_pages`, `…_shrink_after_compaction_returns_pages`, `…_shrink_proven_behaviour_never_compacts`, `…_compact_on_request_shrinks_at_dispatch_end`, `…_compact_state_noop_under_keep` | one trial per choice: `committed` after a state that grew to 10⁵ nodes and shrank to 10³ stays (keep), falls after the fallback copy (shrink; and does not fall for a proven behaviour), falls after the dispatch that called `compact_state()` (request), and `compact_state()` changes nothing under the other two |
| decision 40 | `error_enforcement_addition/state_policy_missing_in_spawn`, `…_missing_in_spawn_registered`, `…_not_literal`, `…_before_stack_policy` | E2005 at the call in each case (the pattern of the `stack_policy_*` trials) |
| decision 18 | `actors_addition/proven_release_flat_memory` | a proven behaviour inserting and deleting 10⁶ times into a map of bounded size; `#568` (through `get_actor_memory_usage` high water) stays flat |
| decision 19 | `warning_enforcement_addition/state_release_not_proven_alias` (W2300), `error_enforcement_addition/strict_state_release_e2321` | the note names the alias; strict mode errors |
| §4.1 (P1) | `warning_enforcement_addition/state_release_branching_versions` | two updates from one old version: unproven |
| §4.1 (P2) | `warning_enforcement_addition/state_release_version_kept_twice` | `{ a: m2, b: m2 }`: unproven |
| §4.1 dropped slot | `warning_enforcement_addition/state_release_slot_replaced` | the slot replaced wholesale: unproven (or accepted, per Lee's §12 choice) |
| decision 20/21 | `actors_addition/evacuation_fills_exact_holes` | retire then evacuate nodes of the same size; the edge does not move |
| decision 28 | `actors_addition/fallback_copy_compacts_holes` | an unproven behaviour; `#568` equals the live state after each dispatch |
| decision 31 | `actors_addition/crashed_actor_queued_message_buffers_released` (design §18.6) | 1,000 restarts with queued messages; process RSS flat |
| decision 32 | `actors_addition/forwarded_message_not_copied` | a relay actor forwards 10⁵ messages; the allocator probe counts no copies |
| decision 33 | `actors_addition/reply_in_caller_stack_pops_with_frame`, `actors_addition/reply_too_large_for_lowered_reservation` | the reply is below the parked SP and gone after the frame; `(:explicit, :reservation_exceeded)` on the caller (was `:stack_exhausted`, decision 39) |
| decision 15 | `actors_addition/spawn_state_in_child_base` | the spawner's frame pops before the child's first dispatch; the child reads its state intact |
| decision 11 | `supervisors_addition/supervised_child_restarts_with_version` (design §18.6) | 1,000 restarts, each start a copy, memory bounded |
| decision 34 | `memory_region_addition/alloc_region_frame_area_returned` | a region allocated in a callee, refs returned, valid in the caller |
| decision 35 / E2302 | `error_enforcement_addition/write_ref_fresh_into_state_cell`, `write_ref_fresh_into_param_cell`, positive `write_ref_old_into_state_cell` | the rule of §6.3 |
| decision 22 / E2301 | the `send_then_use_*` catalogue of design §18.6 | use after an explicit move |
| decision 24 / E2242 | `device_window_used_after_spawn_device`, `device_window_sent_twice` (board) | single owner |
| decision 36 / E2300 | `error_enforcement_addition/frame_buf_to_retaining_wrapper`, positive `ffi_addition/retained_buf_in_ffi_arena` | retention declared and honoured |
| decision 26 / §10 | `error_enforcement_addition/state_exceeds_lowered_reservation` | `:reservation_exceeded` at evacuation (was `:stack_exhausted`, decision 39); `:max_restarts` ends the loop |
| decision 37 | `ordered_data_structures/no_op_change_returns_unchanged`, `change_result_variants` (design §14.2) | the result sums |
| decision 13 | `ordered_data_structures/persistence_old_versions_valid` (design §14.2) | R3 on the stack |
| decision 38 / Q19 | `compile_defects_unbound_rec_record_field_addition` (E2010) | an unbound `rec` in a record field is rejected |
| §9.4 | one `zero_growth_*` per case of design §19.2, measured as stack and state size | nothing grows for the actor's life |
| board | `stack_budget_board_addition/state_chain_1000_actors` | 1,000 actors with small states resident, heap left for the program |

### 11.4 What each smoke test replaces

A fixed point proves two things: that the compiler built by itself compiles the whole tree identically (gen3 == gen2), and that every trial passes under that compiler. Between phases the first is replaced by **building the compiler's own units with the phase's compiler and running the result on `trials/base`**, which catches miscompilation of the compiler's own idioms without a second generation; the second by the per-phase suite list in §11.1. What is lost until phase 10 is the byte-identity check, which catches nondeterminism (an uninitialised word in a frame region, an address-dependent ordering); phase 0's `.sams` diffs and the allocator-probe trials are the partial substitutes.

### 11.5 Cost model (operations, never GC-like)

| Operation | Cost |
| --- | --- |
| frame allocation | 2–4 instructions (`SUB SP`, `MOV`), plus a page fault per 16 KB of new depth (hosted) or a chunk take per chunk (board) |
| frame pop | 0 (SP restore, as today) |
| return in return position (adoption) | 0 copies; the callee's dead fixed part (its frame size) stays until the consumer's evacuation |
| return bound at a consumer | one walk over the new nodes (one descriptor read per word), 2 copies of their bytes (hosted) / 1 (board), one forwarding write per node; REF1 cells add a table probe each |
| persistent update of a path of `k` nodes | `k` frame allocations, `k` `retire` tests (3 instructions each; +1 log append when proven and in state) |
| dispatch end, proven | evacuation of the new nodes as above; `O(retired)` free-list pushes; `O(new nodes)` free-list pops or one edge move; one `memcpy` of the edge block |
| dispatch end, unproven (fallback) | one table-based walk and 2 copies of the **whole live state** (1 on the board); table work `O(shared nodes)`; the header zeroed (129 words) |
| send | measure walk + copy walk over the message, 1 copy, one `malloc`; table work `O(ref nodes)` |
| reply | the same, plus one `grow_to` call on the caller's reservation |
| spawn / restart | the same into the child's base |
| end-of-actor | one walk of the pending mailbox (`O(pending)` frees) and the stack unmap (as today) |
| `stack_policy` | unchanged; `_silica_rt_stack_measure`'s scan is bounded by the frames below the edge |
| state area waste | holes of sizes no longer reused; bounded by the nodes retired since the last fallback copy; compacted by the next fallback copy; a proven behaviour that never falls back keeps its holes, bounded by its own retire history, and the trial `evacuation_fills_exact_holes` shows reuse |
| ACB | +64 B per actor hosted; +16 B board (1,000 actors: 16 KB) |

Nothing above depends on a threshold, a timer or the amount of garbage present; every cost is fixed by the program's own actions in that dispatch.

### 11.6 Specification and document changes (Sonnet, from this design)

| Document | Change |
| --- | --- |
| spec §4.4.2 Region Types | "Region Handle Move Semantics" replaced: a region is a lifetime-scoped area of the actor's stack (decision 12); `alloc_*` allocates in the current frame; the region-less `alloc_*` forms; `retire`; `ref_in_region` removed |
| spec §12.1.1–§12.1.6 | regions on the stack; isolation (E2310); lifetimes as frames and the `write_ref` rule (E2302); spawn copies the state into the child's base (§12.1.5); messages copy into a buffer, `move` copies too (§12.1.6) |
| spec §12.1.4 | Phases B and C replaced by §6 of this document; E2300's new condition; E2301 |
| spec §12.4 | the safety guarantees restated for frames and the state area |
| spec §15.1.1 State Semantics | state at the stack base; dispatch-end evacuation; compiler-proven release, W2300 and strict mode; the fallback's cost |
| spec §15.1.2.2 | the state area at the base and the edge; the release algorithms measure from it; `committed` includes the state area; a composite initial state commits the first page at spawn ("nothing committed at spawn" amended); the ESP32-S3 note gains the state chain |
| spec §15.4.12 child specs | the row spec buffer; each start copies into the child's base (decision 11); E2308 not added |
| spec §16.3.5 | "Message contents are copied into a buffer the receiver reads; a value marked `move` is copied too and the sender may not use it afterwards (E2301)" (design §18.5) |
| spec §22.4 | `committed`/`high_water` include the state area, `retained` excludes it |
| spec §26 / FFI wrapper spec §3.2, §6.2, §7.5 | `retains:`, `alloc_buf_retained`, retention lifetime |
| `common_contract.md` §6, §7 | result sums; no region field; a structure is its root reference; persistence on the stack (§8.4) |
| `data_structure_designs/*.md` | the `r: region(...)` field removed from every family's record |
| `error_codes.md`, `error_codes.jsonld` | E2300 (narrowed), E2301, E2302, E2310, E2311, E2321, E2242, W2300 registered; E2303–E2309, E2312 retired |
| `region_memory_safety_design.md` §13, §16 | the stage table and work breakdown replaced by §11.1 of this document; §18.7 item 2's "any remaining interaction" answered by §2.4 |
| `actor_growable_stack_design.md` §2.3, `actor_stack_growth_plan.md` | the state area in the layout; the edge word; §2.2's ACB fields |
| `actor_memory_budget_plan.md` items B, F, I | the board state chain, ACB 160 B, `heap_reaches` removed |
| ROADMAP rows 4, 15 | status and the single fixed point |
## 12. Proposals for Lee (collected)

User-visible or behaviour-changing choices this document makes where decisions 1 to 38 leave the choice open. None is implemented; each names its alternative. **Lee answered these on 2026-10-24: P1 to P10 and P12 to P14 are confirmed as proposed (the chosen option is marked in each row); P11 is confirmed in substance with a changed reason name (decision 39).**

| # | Proposal | Where | Alternative |
| --- | --- | --- | --- |
| P1 **(confirmed by Lee 2026-10-24: option (A), region-less forms, lifetime and space from the binding's annotation, no transitional old form)** | Region-less allocation forms `alloc_ref(v)`, `alloc_rec(v)`, `alloc_buf(n)`: lifetime and space from the binding's annotation | §3.2 | keep a region argument and have the stdlib pass a `fresh_lifetime()`-made witness it binds per function (more text, same meaning) |
| P2 **(confirmed by Lee 2026-10-24: `retire(r)` with the `|_upd=` marker)** | `retire(r)` builtin (`proc[mem(S)]`, unit result) called by logging updaters where they replace a node; the `\|_upd=` marker on logging updaters | §4.2 | a combined `replace_rec(old, fields)` prim (one call instead of two; cannot express `delete`'s retire without an allocation) |
| P3 **(confirmed by Lee 2026-10-24: W2300 as a warning, E2321 in strict mode, spelled `strict state_release;` at module level; the environment variable is not used)** | W2300 StateReleaseNotProven as a warning; E2321 in strict mode; strict mode spelled `strict state_release;` at module level (recommended) or `SILICA_STRICT_STATE_RELEASE=1` | §4.5 | a `silica.config` directive line (the file is a path list today and would need a directive syntax) |
| P4 **(confirmed by Lee 2026-10-24: a wholesale-replaced slot makes the behaviour unproven, the fallback cleans up)** | A slot replaced wholesale (no update) makes the behaviour unproven, so the fallback compacts the dropped nodes | §4.1 | accept the leak and keep the behaviour proven (faster dispatch, memory held until the actor ends) |
| P5 **(confirmed by Lee 2026-10-24: per-slot copier tables)** | Field-wise copies (one copier table per state slot) at spawn, restart and the fallback copy: two state slots never share nodes afterwards (a version stored in two slots is duplicated) | §4.4, §5.4, §13 item 1 | preserve cross-slot sharing and give up compiler-proven release for actors whose state ever shared (not decidable at compile time: rejected by decision 4) |
| P6 **(confirmed by Lee 2026-10-24: only root-slot lineages are proven)** | Only **root-slot lineages** are proven; an update whose input is an inner structure obtained by a call (`get`) is unproven; stdlib families guarantee no sharing of inner structures between their own slots or do not retire inner nodes | §4.1, §13 item 1 | none that keeps decision 4 |
| P7 **(confirmed by Lee 2026-10-24: `ref_in_region` retired; `canonical_arena_lookup` and `canonical_arena_same` removed)** | `ref_in_region` retired; `canonical_arena_lookup`, `canonical_arena_same` removed (builtins disappear) | §3.2, §9.2 | keep `ref_in_region` answering `true` always (meaningless) |
| P8 **(confirmed by Lee 2026-10-24: E2300 narrowed to non-copying escapes)** | E2300's condition narrowed to references that leave the frame by a non-copying path (a retaining foreign parameter; a shared atomic cell; an undescribed closure) | §6.4 | retire E2300 (decision 16 says it stays, so this document keeps it with a real condition) |
| P9 **(confirmed by Lee 2026-10-24: E2242 DeviceWindowMovedTwice)** | E2242 DeviceWindowMovedTwice for decision 24's single-owner check (device family numbering) | §6.6 | a number in the region family (E2322) |
| P10 **(confirmed by Lee 2026-10-24: sidecar `retains: [param, ...]` and `alloc_buf_retained(n)`)** | FFI retention declared in the sidecar as `retains: [param, …]`; `alloc_buf_retained(n)` for the buffer, effect `external_danger` | §7 | a `retained` marker on the parameter in the Silica `foreign … fn` declaration |
| P11 **(confirmed by Lee 2026-10-24 in substance: the spawner fails; the reason is `(:explicit, :state_too_large)`, not `:stack_exhausted` (decision 39))** | A spawn whose initial state does not fit the child's lowered reservation fails the **spawner** with `(:explicit, :stack_exhausted)` [reason now `(:explicit, :state_too_large)`, decision 39] | §10 | fail the child before its first dispatch (its supervisor then sees a child that never started) |
| P12 **(confirmed by Lee 2026-10-24: grow the ACB (592 B hosted, 160 B board) and the call record (176 B))** | ACB growth to 592 B (hosted) and 160 B (board); call record to 176 B (hosted) | §2.2, §5.3 | reuse the unverified gaps #24..#71, #88..#127 (a trap unless verified by reading every store) |
| P13 **(confirmed by Lee 2026-10-24: frame adoption)** | Frame adoption as the stack form of destination-passing for variable-size results in return position (literal pre-addressed destination-passing is impossible for them on one downward stack) | §3.3 | evacuate at every level (quadratic for non-tail recursion over a list, requirements R4.3's own objection) |
| P14 **(confirmed by Lee 2026-10-24: Q19 enforced everywhere in phase 0)** | Phase 0's Q19 rewrite spells node shapes in the compiler's 25 modules and every stdlib signature before anything else lands | §5.1, §11.1 | enforce Q19 only in message types (contradicts Q19's "everywhere" and leaves the compiler's own structures unsendable) |
| P15 | **Confirmed by Lee 2026-10-24 (decision 40):** the spelling `state_policy(:keep_state_area \| :shrink_after_compaction \| :compact_on_request)` as a required argument directly after `stack_policy(…)` in every spawning form and child spec (§5.4), and the builtin name `compact_state()` (a no-op under the other two choices); a missing argument is E2005, the `stack_policy` pattern, so no new code | §4.7, §5.4 | another builtin name (`state_compact()`); `state_policy` folded into `stack_policy` as a further argument (Lee: separate from `stack_policy`) |

## 13. Problems found

Plain statements of where the decisions, taken as written, cannot be implemented, or where two decisions meet. None reopens a decision; each says what this document did about it and what Lee should look at.

1. **Decision 18 (compiler-proven release) is unsound in the presence of run-time sharing between state slots, which the compiler cannot see.** `retire` frees a node regardless of who else references it. If two slots of the state share a node (a version stored under two fields; the same inner set stored under two keys of a map), an update through one slot retires path nodes the other slot still uses. Every ingredient that creates such sharing is legal: a behaviour storing `m2` in two fields (visible to the analysis, rejected by (P2)); a spawn state built in the spawner with shared versions (copied with sharing preserved by R4.2); an inner structure inserted under two keys (invisible). Decision 4 forbids a run-time check. This document closes the hole by construction: (a) copies into a state area (spawn, restart, fallback) use one copier table per slot, so slots never share (P5); (b) a proven behaviour's new state carries each version into exactly one slot (P2 of §4.1), so evacuation never creates cross-slot sharing; (c) only root-slot lineages are proven and inner-structure updates are unproven (P6); (d) stdlib families whose nodes hold inner structures (the WBT graphs' adjacency sets, maps of sets) must not share an inner structure between two of their own slots if they retire inner nodes: a rule for the stdlib authors and a trial per family (`graph_inner_set_not_shared`). This is a qualification of decision 18, not a change to it, but Lee should confirm (a) because it duplicates memory a program may have expected to share, and (c) because a user's map-of-sets behaviour pays the fallback.

2. **Decision 20 ("adjusting pointers by a constant offset") and decision 21 ("evacuated nodes fill an exact-size hole first") cannot both be literal:** nodes placed in scattered holes are not relocated by one constant. They are reconciled (§3.5, §4.3) by assigning each node's final address during the scratch pass and writing final pointers at once, so the placement pass adjusts nothing; the scratch is still needed on hosted targets because the destination overlaps the dead frames. The observable behaviour (two copies of the new nodes, holes filled first, the edge extended last) is exactly what the two decisions say.

3. **Decision 2's destination-passing cannot be literal for variable-size results.** A callee cannot build a result of unknown size inside its caller's frame on a single downward stack (§3.3). The document realises "build where the result is kept" as frame adoption for return-position calls (P13) and keeps the X8 slot for static sizes; a reader of R4.3's "as region passing does" should know that region passing in the old sense (an allocator handed down) does not exist on the stack.

4. **Decision 34 makes a region parameter unable to serve as the caller's allocator.** With `alloc_*` allocating in the current frame, a callee that allocates "into" a caller's region allocates in its own frame; the result reaches the caller only by return. Writing such a node into a caller-owned cell is E2302 (§6.3). Trials in `memory_region_addition` that pass a region down and have the callee `write_ref` a fresh node into a caller cell (if any; the `region_move_*` family passes regions down and returns refs, which is fine) will become errors; that is a consequence of decision 34, not a defect, and §11.3 lists the positive and negative trials.

5. **E2300 has no unsafe instance left once every frame-leaving path copies** (return, reply, send, spawn, new state). Decision 16 and design §10 say it stays. The document keeps it with the narrowed condition P8 (a non-copying path: FFI retention, shared atomic cells, undescribed closures). If Lee prefers to retire it, nothing else in the design changes.

6. **Decision 33 (replies into the caller's stack) requires one actor to commit pages of another actor's reservation.** The fault handler attributes a fault to the **current** actor, so a replier faulting inside the caller's reservation would be misread. The document has the replier pre-commit explicitly with `_silica_rt_stack_grow_to(caller_acb, dest)` after measuring the reply (§5.3), and defines the outcome when the caller's lowered reservation is too small (`reply_set = 4`, the caller fails). The futex-path park needs a published SP with a margin under the runtime's wait frames (§5.3, the constant `K`); on the board a reply that does not fit the caller's current chunk takes a new chunk in the caller's chain. These are mechanisms, not conflicts, but each is a place where a mistake is a silent overwrite of a parked actor's frame, so the trials `reply_in_caller_stack_pops_with_frame` and `reply_too_large_for_lowered_reservation` are in the phase-4 gate.

7. **Decision 38 and Q19 enforcement reach the compiler's own source.** `root: ref?(L, normal, rec)` in a record field is an unbound `rec` and must be spelled with the node shape; it appears in the inline atom-table type that hundreds of compiler signatures carry. The rewrite (P14) is mechanical but inflates every such signature; the type-surface memo is the mitigation and §11.2 measures it first.

8. **Decision 2 ("nothing to a heap") and decision 7 (mailbox buffers), 33 (the call record), 36 (the FFI arena), the release log and the row spec buffer.** Runtime-owned memory outside the stack remains (§2.7). Each has one owner and one release path and none is addressable by user code as memory, which is how the document reads decision 2; it is listed so that the reading is explicit.

9. **The ESP32-S3's `silica_rt_state_release` / `silica_rt_heap_reaches` (depth-4 reachability at dispatch end) is a run-time reachability heuristic** of the kind decision 4 excludes. It is removed with the state chain (§9.3); until phase 9 the board keeps it, so the board's behaviour differs from the hosted one for the length of the chunk. Lee's board gap note (ROADMAP "Open item") already records that the board lags.

10. **Decision 26/27 and `get_actor_memory_usage`'s four fields.** With the state area inside the committed run, `committed` and `high_water` include state and `retained` does not (§2.4). The specification fixes four fields (§22.4); a program that read `committed` as "stack in use" sees state too. No new field is added; the specification sentence is amended (§11.6).

11. **`main` under decision 9.** `main` has no dispatch end and no state area; everything it builds is frame memory freed at pops, and its stack is the OS thread stack (8 MB on macOS). A `main` that binds a large structure result and keeps it for the program's life holds it in its frame, which is the small-main rule's intent; a `main` that builds a 100 MB string in a loop now runs out of its 8 MB stack where today it grew an arena. This is the memory model Lee chose for `main` (decision 9) and the small-main rule (memory note) is the documented answer; §11.3's `trials/base` run under each phase's compiler is where a `main` that no longer fits would show.

12. **Decision 32's "a part that owns its own buffer" has no instance** in this design: a message is one exact-size buffer, so only the whole message can be forwarded (§5.2). The rule is implemented for the whole message; nothing is lost because a part never had a buffer of its own.

## Revision history

- 1.2 (2026-10-24): decision 40 (the programmer chooses how the state area gives memory back) added: ACB word `#576`/byte 157 and request flag (§2.2), §2.4 note, new §4.7, spawn argument and the spawning forms (§5.4), phase 3 and the trials (§11.1, §11.3), proposal P15 (§12).
- 1.1 (2026-10-24): Lee's answers applied: P1 to P10 and P12 to P14 confirmed (chosen options marked in §12), P11 confirmed with the reason `:state_too_large`; the single fixed point moved after the ESP32-S3 phase (§11.1 phases 8 to 10, §11.4); failure reasons split by cause (decision 39, §10, phase 0), `:stack_reserve_failed` keeps its name.
- 1.0 (2026-10-24): first version, written by Fable at Lee's request from requirements §2A decisions 1 to 38 and §7.5; one fixed point after all phases (Lee's correction of 2026-10-24 applied in §11.1).
