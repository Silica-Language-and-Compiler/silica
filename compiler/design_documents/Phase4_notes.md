# Chunk 15 phase 4: running notes (Fable)

Design: [chunk15_stack_memory_design.md](chunk15_stack_memory_design.md) §5 (5.1 the copier and the mailbox buffer),
§11.1 row 4; preparation: [Phase4_prep.md](Phase4_prep.md) §2 rows 4, 5, 12, 13; phase 3's copier:
[Phase3_notes.md](Phase3_notes.md) §10.8. Mac tree (`compiler/src/emitter/apple_silicon_mac/terms/`) only; the Linux
twins and the board are untouched. Nothing here was built or run by the implementing agent (Haiku builds, Sonnet reads).

## 1. Stage 4a: the mailbox buffer (2026-10-31, source only)

### 1.1 The send path before 4a (read 2026-10-31)

* Emitter, `prims/prims_actors.silica`. `emit_prim_op_with_atoms` routes `send`, `actor_cast`, `actor_cast_device`,
  the three registered casts, `actor_call`, `actor_call_registered` and `timer_cast` through `send_deep_copy_asm(term,
  outer_reg, table)` (message in X10, target in X11), which (a) walked a described message out of the sender's frames
  into the sender's implicit heap (`stack_value_to_heap_asm` -> `L_ev_heap`, descriptor `L_evs_<fn>_<node>_0`), then
  (b) for a record/tuple/sum type reaching a ref or buffer (`md_type_needs_copy`) deep-copied it with the module-local
  `L_mc_root` (`term_message_copy.silica`: shells from `_silica_rt_region_alloc`, refs shared as words since no REGION
  words remain, lists and strings copied as words), unless the SIR tagged the send `|mv` or the function's `|_mvs`
  marker named the site (last use: the heap copy was handed over). `actor_message_copy_x10` then one-level promoted an
  aggregate of an undescribed type into the heap (`heap_promote_stack_aggregate_x0`, `_silica_rt_region_alloc`).
  `emit_send` / `emit_actor_cast*` then `MOV X0, X11; MOV X1, X10; BL _silica_rt_actor_<entry>`.
* Runtime, `prims/prims_actors_runtime_asm.silica`. `_silica_rt_actor_cast(X0 ref, X1 msg)` set `X2 = 0` and ran
  `_silica_rt_actor_cast_flagged(X0 acb, X1 msg, W2 owned)` under `_silica_rt_ref_call`: a 152 B `calloc` node with
  `+8` the message word, `+16` needs_reply 0, `+24` 1, `+32` the owned-payload kind, enqueued at ACB `#128`;
  `LBB3_dead_locked` freed the node only. `_silica_rt_actor_send` is the cast returning 0. The registered casts resolve
  the registry and tail-call `_silica_rt_actor_cast` (X2/X3 untouched). The dispatch (`LBB1_process`) stores the node at
  ACB `#240`, runs the behaviour with X0 = `[node+8]`, and `LBB1_free` frees the node after the owned-payload release;
  `_silica_rt_actor_signal_pending_call_deaths` frees the active cast node and every pending node at actor end. The
  runtime's own casts: `_silica_rt_timer_fire` and the exit-report sink (`prims_actors_child_table_asm.silica:2461`)
  through `ref_call`, one direct `bl _silica_rt_actor_cast_flagged` (`:5258`).
* Runtime copier (phase 3, `prims/prims_actors_state_asm.silica`): `_silica_rt_state_measure(value, desc)` and
  `_silica_rt_state_copy(value, desc, dest, end, delta)` with the CCB in X20 (mode 0 = bump up), one table per state
  SLOT (X21 = 1 at the root empties the table at every node-bearing spine word), KIND 7 lists copied handle + whole
  chunks from the cursor (the last chunk's next cleared), KIND 8 strings header + bytes.

### 1.2 What 4a does (design §5.1, the mailbox buffer only)

* **Which sends.** The cast family: `send`, `cast`, `cast` to a device actor, the three registered casts. A `call`'s
  message and a timer's keep the arena copy (`send_deep_copy_asm`) in 4a: a reply may still point into the message
  (today's reply copy shares refs, lists and strings as words and `|_mvr` elides it; stage 4c makes every reply a full
  copy into the caller's stack, after which the call family switches to the buffer), and a periodic timer re-sends the
  same message word (stage 4e, with `_silica_rt_timer_prepare`).
* **Emitter** (`prims/prims_actors.silica`). New `send_buffer_copy_asm(term, outer_reg, table)`: for a described,
  non-scalar message type (`ev_type_described`, the same test the heap walk used) it emits
  `STR X11,[SP,#-16]!; MOV X0,X10; ADRP/ADD X1, L_evs_<fn>_<node>_0; BL _silica_rt_message_buffer; MOV X10,X0;
  MOV X12,X1; MOV X13,X2; LDR X11,[SP],#16` plus the root-word descriptor rodata (`ev_site_descriptor_rodata`; the
  `L_mcs` aggregate descriptor of the old deep copy is no longer emitted at these sites). "" otherwise, and
  `actor_message_copy_x10` then one-level promotes an undescribed aggregate as before (no buffer). New
  `cast_buffer_args_asm(deep)` emits `MOV X2,X12; MOV X3,X13` (buffered) or `MOV X2,XZR; MOV X3,XZR`; `emit_send`,
  `emit_actor_cast`, `emit_actor_cast_registered`, `emit_actor_cast_dangerous_registered`,
  `emit_actor_cast_device_registered` place it before the `BL`. No frame walk to the heap at these sites any more: the
  copier reads the message where it lies (frame, heap, state area, literal) and the sender's original pops with its
  frame. `|mv` and `|_mvs` no longer skip the copy at a cast (decision 6; the forwarding of §5.2 is stage 4e).
* **Runtime copier** (`prims/prims_actors_state_asm.silica`). `_silica_rt_message_measure` and
  `_silica_rt_message_copy`: the phase-3 measure and copy entered with the spine flag OFF (X5 = 0 selects
  `Lstc_run_flat`), so ONE table serves the whole message and sharing between any two parts is kept (R4.2); the walkers,
  sizes and the KIND 7/8 copies are phase 3's unchanged. New `_silica_rt_message_buffer(X0 value, X1 root desc) ->
  X0 root, X1 bytes, X2 block`: value below 65536 or measure 0 -> inline (X1 = X2 = 0, X0 as given); else
  `malloc(bytes)`, copy with delta 0, overrun aborts (`_silica_rt_abort_state_copy`), no memory ->
  `_silica_rt_region_alloc_failed` (fails the sender; main aborts).
* **Runtime send** (`prims/prims_actors_runtime_asm.silica`). `_silica_rt_actor_cast(X0 ref, X1 root, X2 bytes,
  X3 block)` runs the new body `_silica_rt_actor_cast_flagged_buffered` (X2 bytes, X3 block, owned flag 0) under
  `ref_call`; `_silica_rt_actor_cast_flagged` keeps its W2 signature for the runtime's own casts and enters the same
  body with bytes = block = 0 (`LBB3_entry`; frame 48 -> 64 B, X23 bytes, X24 block). The node stores bytes at `+40`
  and the block at `+48`. A dropped message (no target, ended target, call-only target, no node) frees the block
  (`LBB3_dropped`; Q17 / decision 7). `_silica_rt_actor_send` passes X2/X3 through; the registered casts already did.
* **Dispatch end.** `LBB1_free_user` (reached when node `+32` = 0): `free([node+48])` unless ACB `#600` is set
  (below). `_silica_rt_actor_signal_pending_call_deaths`: the active cast node's buffer is freed under the same rule
  (`LBBsigpend_active_user`), every pending user node's buffer unconditionally (`LBBsigpend_free_user`; decision 31).
  The call-reply path (`LBB1_reply_drain`) does nothing new: a call node's `+48` is 0 in 4a.
* **The retain flag, ACB #600** (was spare since 3c; interim, goes with the implicit heap in 4e/phase 5). Cleared at
  every dispatch start (where the node is stored at `#240`). Set by `_silica_rt_region_alloc` for the current actor
  (every one-level promote and `L_ev_heap` evacuation goes through it: an undescribed message or spawn state, a reply
  shell, the runtime list/string builders, `L_mc_alloc_shell`) and by the epilogue of a behaviour whose state type is
  composite but undescribed (`bmv_state_asm`, false arm), since `_silica_rt_state_dispatch_end` does not copy such a
  state out of the buffer. When set, `LBB1_free_user` keeps the buffer: a leak of the same kind as the sender's arena
  copy was until now, never a dangling pointer. Described states (evacuate / copy_all) and every buffered send copy
  out of the buffer, so the common case frees.

### 1.3 Node layout (hosted, 152 B; user message nodes)

`+8` the message: the copy's root (the block's start for every kind but a bare buffer, whose root is its element
pointer at block + 8) or the inline word; `+16` needs_reply; `+32` owned kind (0); `+40` buffer bytes (design §5.1,
for 4e's forwarding); `+48` buffer block (NEW, what is freed; 0 = no buffer); `+56` caller ACB; `+136` reply_set;
`+144` reply. An owned exit report (`+32` = 2) still uses `+40/+48` for its arena snapshot
(`_silica_rt_owned_record_begin`); every reader tests `+32` first. Readers of `+48`: `LBB1_free_user`,
`LBBsigpend_active_user`, `LBBsigpend_free_user`, `LBB3_dropped` (X24 before the node exists). Comment block updated
at the top of `prims_actors_runtime_asm.silica` ("152 B message nodes").

### 1.4 Decisions taken here

* Runtime copier, not `L_mc_root` (design 5.1 names `L_mc_root`): phase 3 already has the destination-cursor copier
  with KIND 7/8 in the runtime unit (Phase3_notes §10.3's reasoning), so the message buffer reuses it through a flat
  (one-table) entry; `L_mc_root` stays only for the call reply until 4c, after which 4e deletes it with
  `L_mc_premap/map_region/is_canonical/new_region/reserve/alloc_shell` (rows 8, 11).
* Decision 30's sharing of list CHUNKS through the table (two handles sharing a tail share the copied chunks) is NOT
  implemented: the copier copies a spine once per handle (Phase3_notes §10.1 "Sizes"); a per-message table makes
  handles shared, chunks not. Deferred to 4e with a note that a table hit on a chunk must re-walk its element words
  from the second handle's cursor.
* Call family and timers left on the arena copy (above); the free of a call node's buffer belongs to 4c (free at
  `LBB1_reply_drain_done`, after the reply copy, never by the caller).
* `+48` added for the block because the bare-buffer root is not the block's start; the alternative (`root & ~15`) was
  rejected as a malloc-alignment assumption.

### 1.5 Not verified (Haiku builds, Sonnet reads)

Nothing built or run. Expected: `.ascomp` drift in `__silica_runtime` and in every module with a cast site (the
`L_evs_` descriptor now follows the cast, the `L_mcs` one is gone, four extra MOVs before each cast); `.sout` must equal
`.scout` everywhere. Trials to watch: `actors_addition` (`record_message_casts_hold_state`, `tuple_message_casts_hold_state`,
`identity_compare`, the `*_no_heap_growth` and `zero_heap_growth_*` ones: growth can only fall), `bees_regions_addition`
(`bees_sd7_message_region_released*`, `bees_term`), `device_actor_addition`, `supervisors_*` (FailureReporter casts are
runtime casts, unchanged), `scheduler_policy_addition`, `cpu_discovery_and_spawn_pinning`. A behaviour that keeps a part
of a cast message in an UNDESCRIBED state (a structure with `rec`, a type parameter) now leaks the buffer instead of the
sender's arena copy; one that sends a part on inside an undescribed message does the same (the flag is set in the sender
for its own current buffer only when it is itself serving a cast). Not checked: that no runtime path other than those
listed reads node `+40/+48` of a user node.

### 1.6 For stage 4b (dead-send and end-of-actor frees, `_silica_rt_actor_*`)

4a already covers rows 12 and 13 of Phase4_prep §2 for the cast family (dropped-send free, pending and active frees).
Left for 4b/4c: the call record (176 B, `+152` parked SP, `+160` reply bytes, `+168` holders) and the call family's
buffer; `heap_used()` (unchanged by 4a: casts no longer bump the heap, so the 17 hosted trials that assert zero growth
still hold). No design contradiction found that blocks 4b; the one silent point (which word holds the block when the
root is not the block) is decided above.

## 2. Stage 4a: gate result (2026-10-31)

Built with the published phase 3 compiler as builder (sha1 85f61850...). The runtime assembles after moving the
buffered cast's `.cfi_startproc` below its global label. The 12-suite gate: no `.scout` differences, no golden
failures, no faults, no compilation or link failures. Assembly goldens refreshed by copying `.sams` where the output
matched (rule: Lee 2026-10-30), 436 trials, and the new string-reply trial got its first `.ascomp`.

## 3. Stage 4b: forwarding-only `|_mvs` (2026-10-31, source only)

Design §5.2 (decision 32). Mac tree only; nothing built or run (Haiku builds, Sonnet reads).

### 3.1 Before 4b (read 2026-10-31)

* `term_message_copy@fn_copy_markers` wrote `|_mvs=,<node>,...` for every send AND spawn prim (`mc_is_send_prim`,
  `mc_is_spawn_prim`) whose operand type `md_type_needs_copy` and whose operand was a last use by
  `mc_site_is_last_use`: taint closure of the operand's vars (`mc_closure`), rejected when poisoned (`!`) or when
  the closure met ANY parameter (`mc_intersects(params, set)`), accepted when `mc_after(body, set, site) == 1`.
  It wrote `|_mvr=1` when the reply type needs a copy and no reply site needs it (`mc_reply_needs_copy`).
* Consumers: `prims_actors@send_deep_copy_asm` (the call family and `timer_cast`, the arena copy) skipped the
  `L_mc_root` deep copy when `md_site_elided(outer_reg, node)` or `|mv`; `send_buffer_copy_asm` (the cast family,
  4a) ignored the marker (decision 6) and always called `_silica_rt_message_buffer`; `md_reply_copy_asm` returned
  "" under `md_reply_elided`. Spawns never read the marker (`spawn_state_desc_asm` comment).
* Runtime: no forwarding entry; a served node's `+40/+48` were read only at `LBB1_free_user`,
  `LBBsigpend_active_user`, `LBBsigpend_free_user` (§1.3).

### 3.2 What 4b does

* **`|_mvs` reinterpreted** (`term_message_copy.silica`, new block "forwarding"): set only for a behaviour
  (`mc_is_behaviour_return`: `(:reply,` / `(:no_reply,`), only at cast-family sites (`mc_is_cast_prim`: `send`,
  `actor_cast`, `actor_cast_device`, the three registered casts; never a call, a timer or a spawn), only when the
  operand is a kind-1 var naming parameter 0 bare or `%`-prefixed (`mc_operand_is_param`; a projection never
  qualifies), and `mc_site_forwards_message` holds: closure of `{msg, %msg}` not poisoned, not meeting another
  parameter (`mc_param_set_both` of the rest), no `write_ref` whose subtree mentions the set (`mc_write_mentions`:
  a part written into a cell could reach the state through it), no result position mentioning the set
  (`mc_result_mentions`: lets and case arms down to the result tuple; the §5.2 sink test, over the whole tuple), and
  `mc_after(body, set, site) == 1` (today's last-use rule, kept as §5.2 says). `mc_site_is_last_use`, `mc_closure`,
  `mc_after` are unchanged.
* **`|_mva` (interim, new)**: the OLD rule (`mc_elided_sites`, unchanged) under a new name, read only by
  `send_deep_copy_asm` through `md_site_arena_elided`. Reason: the call family and timers still copy through the
  arena in 4b, where a last-use local's elision is what keeps `L_mc_root` from allocating shells
  (`_silica_rt_region_alloc`), which the `*_no_heap_growth` trials measure; dropping it before the call family
  moves to the buffer (4c) would change `heap_used()` output. `|_mva`, `mc_elided_sites` and
  `md_site_arena_elided` go with `L_mc_root` and `send_deep_copy_asm` in 4c/4e. `md_site_elided` is replaced by
  `md_site_forwards` (`_mvs`) and `md_site_arena_elided` (`_mva`); exports updated.
* **Emitter** (`prims_actors@send_buffer_copy_asm`): at a forwarding site the call becomes
  `ADRP/ADD X2, <this function's entry symbol>; BL _silica_rt_message_forward` instead of
  `BL _silica_rt_message_buffer`; everything around it (X0 value, X1 `L_evs_` descriptor, X10/X12/X13 results, X11
  parked, `cast_buffer_args_asm`) is identical, so the node takes the forwarded words at `+40/+48` through
  `_silica_rt_actor_cast` exactly as a fresh copy's, and `LBB3_dropped` frees a forwarded block on a failed send.
* **Runtime** (`prims_actors_state_asm.silica`, after `_silica_rt_message_buffer`): `_silica_rt_message_forward(X0
  value, X1 desc, X2 fn entry) -> X0 root, X1 bytes, X2 block`. Forwards only when ALL hold: an actor is current;
  `[ACB #8] == X2` (the function is the behaviour being dispatched, not a behaviour-shaped helper it called whose
  caller may still use the message; the dispatch runs `blr` on `[ACB #8]` and `_silica_rt_beh_proven_store` reads
  that entry's prefix word, so it is the raw symbol); `[ACB #600] == 0` (no shallow copy in this dispatch may hold a
  pointer into the buffer; conservative: any arena allocation sets it); node `[ACB #240]` present with `+32 == 0`
  (plain user message, not an owned report) and `+16 == 0` (a cast node: a call's buffer, when 4c gives it one, is
  4c's decision); `+48 != 0` (a buffer exists: inline and runtime-cast messages fall through) and `+8 == X0` (the
  value IS the buffer's root). Then X1 = `+40`, X2 = `+48`, both words of the serving node zeroed, X0 as given.
  Otherwise it tail-calls `_silica_rt_message_buffer` (the copy, as at every other site). Local labels `Lmfw_*`.
* Dispatch end: `LBB1_free_user` / `LBBsigpend_active_user` unchanged in code (`+48 == 0` already skips); comment
  only. `LBB1_reply_drain_done`: NOTHING added. 5.2 needs no call-buffer free in 4b: no path puts a buffer on a call
  node (forwarding is cast-family only and `_silica_rt_actor_call` still takes the arena copy), so `+48` of a call
  node is still always 0; the free after the reply copy under the ACB #600 rule stays 4c's (§1.4).

### 3.3 Deferred to 4c (the §5.3 boundary)

* **`|_mvr` removal and `mc_reply_needs_copy` deletion** (5.2's second and third bullets): "every reply is copied
  into the caller's stack (decision 33)" IS §5.3. Removing the marker now would make every pointer-bearing reply an
  `L_mc_root` copy into the caller's ARENA (more `_silica_rt_region_alloc`, observable in the `*_reply_no_heap_growth`
  trials) with no stack destination to copy into. Untouched: `fn_copy_markers` still writes `|_mvr=1`,
  `md_reply_elided` / `md_reply_copy_asm` unchanged, the call-family reply copy unchanged (task rule).
* **The call family's buffer** and the free at `LBB1_reply_drain_done` (above). When 4c moves the call family onto
  the buffer, `|_mva` and `send_deep_copy_asm` go, and `_silica_rt_message_forward`'s `+16 == 0` test is the place to
  decide whether a call's message may be forwarded (a reply that mentions the message is never a last use, so the
  compile-time rule already excludes the hazard; the runtime test is belt and braces).
* `md_prim_value_is_move` / `md_prim_is_move_wrapper` (design §5.1 "become dead ... removed"): still read by
  `send_deep_copy_asm` and `mc_reply_needs_copy`; they go with those in 4c.

### 3.4 Not verified (Haiku builds, Sonnet reads)

Nothing built or run. Expected drift: `__silica_runtime` `.ascomp` (the new routine) in every unit, and the
`.ascomp` of every module with a forwarding site (two extra instructions and the entry's symbol before the
`BL`); `.sout` must equal `.scout` everywhere. Where to look: `actors_addition` (`actor_behavior_forward_cast`,
`actor_cast_ping_pong_roundtrip`, the relay/forward shapes), `bees_regions_addition`, `device_actor_addition`,
`supervisors_*`. The §5.2 whole-parameter rule depends on the SIR spelling of a parameter reference (a kind-1 var
named `p` or `%p`; `sir_state_release` accepts both, so both are accepted here): if a parameter reference is
lowered differently (through a let alias), no site is marked and the output is 4a's. The intra-procedural sink
test cannot see a message part stored into a state cell inside a called function; the region checker (phase 6,
E2302) is the full rule, and until then such a behaviour must not forward (it will not if it binds the result).
Not checked: that no runtime path other than those listed in §1.3 reads node `+40` of a user node after the
forward zeroes it.

## 3b. Stage 4b: gate result (2026-10-31)

Built with the stage 4a compiler as builder (sha1 560c2463...); the new compiler is sha1 de6b6bed.... The runtime
assembles. The 12-suite gate is clean except 13 `traits/` assembly units in supervisors_addition, which are not
copied (rule: traits units are left alone). No golden copies were needed.

## 4. Stage 4c: replies into the blocked caller's stack (2026-10-31, source only)

Design §5.3 (decision 33, the extended call record), §5.2's `|_mvr` removal, and the call family's buffer
(§3.3 above). Mac tree only; nothing built or run (Haiku builds, Sonnet reads).

### 4.1 Before 4c (read 2026-10-31)

* **The reply path, emitter.** `emitter_core` (2959) ran, at the epilogue of every behaviour-shaped function,
  `prims_actors@behaviour_result_evacuate_asm` (a described composite reply walked out of the behaviour's frame into
  the REPLIER's heap by `L_ev_heap` / `L_ev_heap_shell`, descriptor `L_evb_<entry>_r_0`; a `_silica_rt_region_alloc`
  that set ACB #600) and then `behaviour_result_move_asm`, whose reply part was `bmv_reply_string_asm` for a bare
  string (a run-time string copied byte by byte into the CALLER's arena through `_silica_rt_region_alloc_in`, a
  literal left as a pointer) or `bmv_reply_asm(rbytes, ...)` for every other type: `rbytes = composite_move_bytes`
  (the shell size of a record or tuple; 0 for a list, a ref, a bare type parameter, so those replies were passed
  as pointers into the replier's state area or heap, the H4 hazard of `reply_after_callee_ended`), the
  `cast_skip` test (node `+16` = 0: a cast that reached a call-style behaviour), then `reply_copy` when
  `md_reply_copy_asm` gave one (`md_type_needs_copy(rt)` and not `|_mvr=1`: `L_mc_root` with the shell ACB =
  the caller, node `+56`, descriptor `L_md_<entry>_r`), else `heap_promote_reply_x0` (the one-level promote
  into the caller's arena, `_silica_rt_region_alloc_in`). The copied root replaced the tuple's `+8`.
* **The reply path, runtime.** `LBB1_post_beh` read the tuple's `+8` into X21; `LBB1_reply_drain_done` (lock `+72`
  held) stored X21 at node `+144`, `1` at `+136`, `_silica_rt_call_wrapper_wake`, unlock. The node was never
  touched by the replier after the unlock; the caller freed it.
* **The call record.** `_silica_rt_actor_call_acb(X0 acb, X1 msg)`: a 152 B `calloc` node, `+8` message, `+16` = 1,
  `+56` the caller's ACB (0 in main), `+24` futex, `+72` lock, `+48` the parked carrier actor, `+136` reply_set
  (0 waiting, 1 replied, 2 target died), `+144` reply. The caller (`LBB4_wait_start`) took `+72`, parked
  (`_silica_rt_ctx_save`: 176 B below its SP, recorded at ACB #464; the carrier loop then runs on the carrier's
  stack) or waited on the futex (`LBB4_7`), and at `LBB4_8` read `+144` / `+136`, unlocked, freed the node and
  returned the reply word (X1 = 1 when `+136` = 2). Both `_silica_rt_actor_call` and `_acb` popped their frames
  SP-relative. `_silica_rt_actor_call` has no runtime-internal caller (`_registered` tail-calls it).
* **The call's message.** `emit_prim_op_with_atoms` routed `actor_call` and `actor_call_registered` through
  `send_deep_copy_asm` (the arena copy, `|_mva` elision, `L_mc_root`); `emit_actor_call*` passed X0/X1 only. A
  call node's `+40/+48` were always 0.
* **Markers.** `fn_copy_markers` wrote `|_mvr=1` when `mc_reply_needs_copy` found no reply site needing a copy;
  `md_reply_elided` read it in `md_reply_copy_asm`. `md_prim_is_move_wrapper` was read only by
  `mc_reply_needs_copy`; `md_prim_value_is_move` also by `send_deep_copy_asm` and `mc_elided_sites`.
* **The emitted call site.** `emit_actor_call` = `MOV X0, X11; MOV X1, X10; BL _silica_rt_actor_call` then the
  result move; no pre-call SP store and no adoption (the reply was a heap pointer). A user call stores SP at
  `[X29, #24]` (`call@call_precall_sp_asm`) and adopts a callee's frame with `L_adopt` (`prims_memory`:
  `[SP, pre-call SP)` becomes the bottom of the frame's dynamic part, the floor `[X29, #16]` moves to SP).
* **Runtime copier entries.** `_silica_rt_message_measure(X0 value, X1 root desc) -> X0 bytes (-1 no table)`;
  `_silica_rt_message_copy(X0, X1, X2 dest, X3 end, X4 delta) -> X0 root, X1 = 0 (1: no table)`; mode 0 bumps up
  from `dest`, overrun aborts. `_silica_rt_stack_grow_to(X0 acb, X1 address) -> 0 grown, 1 exhausted, 2 host
  refused, 3 already committed`; it assumes a managed reservation (#272 / #280).

### 4.2 What 4c does

* **The call record** (`prims_actors_runtime_asm.silica`, `_silica_rt_actor_call_acb`): `calloc(1, 176)`. Fields now:
  `+8` message, `+16` needs_reply = 1, `+24` futex, `+32` owned kind (0), `+40` the message buffer's BLOCK (a call
  record differs from a cast node here: `+48` of a call record is the parked carrier actor, written by
  `LBB4_wait_start` and read by `_silica_rt_call_wrapper_wake`, so the block cannot share it; a call's buffer is
  never forwarded, so its byte count is not kept), `+56` caller ACB, `+72` lock, `+136` reply_set (0 waiting,
  1 replied, 2 target died, 4 reply too large; 3 reserved for `call_with_timeout`), `+144` reply, `+152` the
  published SP, `+160` the reply's bytes, `+168` holders (2 at creation). Readers of a call record's `+40`:
  `LBB1_reply_drain_done`, `_silica_rt_actor_signal_call_death` (both zero it after the free). Cast nodes keep 4a's
  `+40` bytes / `+48` block.
* **Publishing the SP.** Not at the park (design) but at the record's creation, before the enqueue: `+152 = SP of
  _silica_rt_actor_call_acb - 1024`. Reason: the replier can run its epilogue before the caller has taken `+72`
  (a fast reply is already handled by `LBB4_wait_start`'s `reply_set != 0` test), so a published-at-park SP could
  be 0 when read. The margin covers everything this thread runs below that SP until it lowers SP onto the reply:
  the mail signal, the lock, the 176 B context save or the futex wait, the wake-up lock and unlock. The design's
  512 is doubled because the window is longer than the design's wait-only window; the constant is one immediate.
  The carrier loop runs on the carrier's stack (`Lcar_loop` switches SP), so nothing else touches the parked stack.
* **Replying** (`prims_actors_state_asm.silica`, new `_silica_rt_reply_place(X0 value, X1 root desc) -> X0 root`):
  answers the value as given below 65536, outside an actor, with no node at ACB #240, when node `+16` = 0 (the
  `cast_skip` case) or when the measure is 0 (a literal string, a function value); else `bytes =
  _silica_rt_message_measure`, `dest = (+152 - bytes) & ~15`; when the published SP lies in the caller's managed
  reservation (`+56` -> #272/#280) and `dest` is below its base, or `_silica_rt_stack_grow_to(caller, dest)`
  answers 1 or 2, `reply_set = 4` and the value is returned as given; otherwise `_silica_rt_message_copy(value,
  desc, dest, dest + bytes, 0)` (one table: sharing inside the reply kept) and `+160 = bytes`. main (`+56` = 0)
  and a caller whose published SP is outside its reservation (a runtime path on a carrier thread's own stack)
  get no growth call. No lock: `+152` is final before the enqueue and nothing else writes `+136` while the replier
  is alive (3, the abandoned caller, is future work and is the point where the design's step 1 lock matters).
* **Emitter, replier side** (`prims_actors.silica`). `behaviour_result_move_asm`: a frame-free scalar reply type
  emits nothing; a described type (`ev_type_described`, so records, tuples, sums, lists, strings, refs) emits
  `bmv_reply_stack_asm`: `LDR X0, [X0, #8]; ADRP/ADD X1, L_evb_<entry>_r_0; BL _silica_rt_reply_place; LDR X9,
  [SP, #8]; STR X0, [X9, #8]` plus the root-word descriptor rodata (the label the phase-2 heap evacuation used);
  an undescribed composite type keeps `bmv_reply_asm` (the arena path, 4e). `behaviour_result_evacuate_asm` and
  `bev_one` are deleted (`emitter_core` 2959 no longer calls them): the reply is read where it lies, in the live
  behaviour frame, the state area or the message buffer. `bmv_reply_string_asm` is deleted (a string is KIND 8 to
  the runtime copier; a literal measures 0 and stays a pointer).
* **Runtime, reply drain.** `LBB1_reply_drain_done`: stores the reply; frees the call's buffer `+48` (when `+32` =
  0 and ACB #600 = 0; `+40/+48` zeroed either way); sets `reply_set = 1` unless it is 4; wakes; decrements
  holders; unlocks; frees the record only if holders reached 0 (never today). `_silica_rt_actor_signal_call_death`
  (the target died: sets 2) frees the buffer unconditionally (the target's state is gone), decrements holders the
  same way.
* **Runtime, caller side.** `LBB4_8` reads `+144`, `+136`, `+160`, `+152`, decrements holders, unlocks, frees the
  record when it was the last holder; `reply_set` 4 -> `_silica_rt_fail_self(:reservation_exceeded)`; bytes != 0
  -> `SP = (+152 - +160) & ~15`, X2 = 1, and the frame is left through X29 (`LBB4_9_leave`); else `SP = X29 + 16`
  (the entry SP) and the same X29-relative leave. `_silica_rt_actor_call` (64 B frame, X2/X3 kept at `[X29, #48]`,
  zeroed once handed to `_acb`) likewise returns through X29 and restores `SP = X29 + 64` only when `_acb`
  answered X2 = 0; `Lcallw_not_found` / `Lcallw_conv` / `LBB4_dead` / `LBB4r_not_found` free a block that was
  never enqueued.
* **Emitter, caller side.** `emit_actor_call` / `emit_actor_call_registered` (through `emit_actor_call_entry`):
  `MOV X0, X11; MOV X1, X10; <cast_buffer_args_asm>; MOV X16, SP; STR X16, [X29, #24]; BL _silica_rt_actor_call*`
  then `BL L_adopt` for a non-scalar result type (`[SP, pre-call SP)`, the reply plus the dead runtime frames and
  the margin, becomes the bottom of the frame's dynamic part, so the reply pops with the frame) or `LDR X16,
  [X29, #24]; MOV SP, X16` for a scalar one (settles SP when an untyped reference reached a behaviour whose reply
  type disagrees with the site). Routing: `actor_call` and `actor_call_registered` take `send_buffer_copy_asm`
  (the mailbox buffer; a call site never forwards: `mc_is_cast_prim` excludes it and the runtime's `+16` test is
  the belt and braces). `timer_cast` alone keeps `send_deep_copy_asm`.
* **Markers** (`term_message_copy.silica`). `|_mvr` is gone: `fn_copy_markers` writes `|_mvs` and `|_mva` only;
  `mc_reply_needs_copy`, `mc_reply_arms_need_copy`, `md_reply_elided` and `md_prim_is_move_wrapper` are deleted
  (exports updated; `md_reply_copy_asm/3` drops the markers argument and answers "" for a described type too, so
  its `L_md_<entry>_r` rodata is emitted only for the undescribed arena path). `mc_elided_sites` / `|_mva` /
  `md_prim_value_is_move` stay for the timer (4e).

### 4.3 Deferred

* **To 4e** (the implicit heap): `bmv_reply_asm` + `heap_promote_reply_x0` + `md_reply_copy_asm`'s `L_mc_root`
  copy for a reply type the descriptors cannot follow (a type parameter, a trait type): still into the caller's
  arena, as before, and such a promote sets ACB #600 so the call's buffer is kept. `send_deep_copy_asm`, `|_mva`,
  `mc_elided_sites`, `md_prim_value_is_move`, `L_mc_root` and its region helpers: the timer's arena copy
  (`_silica_rt_timer_prepare` re-sends the word). `module_uses_message_copy` is left conservative (a module with a
  described reply still emits `L_mc_root`; harmless, unused there).
* **To 4d** (spawn into the child's base): nothing in 5.3 depends on it; the first-dispatch state path is untouched.
* **Not done from 5.3**: `reply_set` 3 (caller abandoned) and the replier's step-1 lock-and-check belong to
  `call_with_timeout` (chunk 11); `grow_to` answering 2 (host refused) is folded into 4 (`:reservation_exceeded`),
  not decision 39's `:out_of_memory`; the board (`MSG_PARKED_SP`) is out of scope.

### 4.4 Decisions taken here

1. **`+40` for a call record's block.** The first draft put the call's block at `+48` like a cast node's; `+48` of a
   call record is the parked carrier actor (`LBB4_wait_start` writes it after the enqueue, `_silica_rt_call_wrapper_wake`
   reads it), so a carrier actor parking on a buffered call would have lost the block and the drain would have
   freed an ACB. The block lives at `+40` in a call record (bytes are not kept: a call's buffer is never forwarded);
   the record stays at the design's 176 B. Found by reading `LBB4_wait_start` against the drain; nothing built.
2. **Publish the SP at creation, margin 1024** (4.2): closes the fast-reply gap the design's publish-at-park leaves.
3. **The runtime copier, not `L_mc_root`**, as in 4a (Phase4_notes §1.4): `_silica_rt_reply_place` reuses
   `_silica_rt_message_measure` / `_copy` with one table.
4. **The epilogue reads the reply where it lies**: the phase-2 heap evacuation of the reply is deleted rather than
   kept beside the stack copy (one less `_silica_rt_region_alloc` per composite reply; ACB #600 is no longer set
   by a described reply, so the call's buffer frees in the common case).
5. **Holders implemented** (both sides decrement under the lock, the last frees after unlocking) although no
   abandon path exists yet, so that `call_with_timeout` adds only the `reply_set = 3` store.

### 4.5 Not verified (Haiku builds, Sonnet reads)

Nothing built or run. Expected drift: `__silica_runtime` `.ascomp` everywhere (the new routine, the 176 B
record, the X29-relative leaves); every module with a behaviour whose reply type is composite (the `L_evb_` reply
evacuation block is replaced by the `_silica_rt_reply_place` call; the `L_md_<entry>_r` block disappears for
described types; `bmv_reply_string_asm`'s loop is gone) and every module with a call site (buffer args, the
pre-call SP store, `L_adopt` or the SP restore). `.sout` must equal `.scout` everywhere. Where to look:
`actors_addition` (`*_reply_no_heap_growth`, `zero_heap_growth_*`: growth can only fall; `aggregate_return_in_
actor_keeps_stack`; `actor_mailbox_calls_get_death_result_on_exit`; `identity_compare` if it compares a reply's
identity), `region_hazards_open_addition/reply_after_callee_ended` (should now pass: the reply is the caller's),
`supervisors_*` (`call` replies from supervisors, `which_children` records), `bees_regions_addition`,
`carriers_addition` (a carrier actor parking on a call, the resume path, K = 1024 against the park's frames),
`actor_stacks_addition` (a lowered reservation receiving a large reply: new `reply_set` 4 path, untested), the
compiler building itself (one spawn + call + reply per unit). Hazards carried over: a `timer_cast` whose message is
a part of a call's message now dangles as a cast's part has since 4a (the timer's heap walk moves frame nodes
only); a list reply is now copied (KIND 7) where it was a shared pointer, so a trial comparing a reply's identity
with the state's would change. Risk judged highest: the margin K against the deepest frame chain between the
enqueue and `LBB4_8` (`_silica_rt_actor_mail_signal` -> `_silica_rt_carrier_push`, the os_unfair_lock slow
path), and `L_adopt` after a call in a frame whose transient area holds an sret slab (same situation as a user
call in an argument position, so not new).

## 4b. Stage 4c: gate result (2026-10-31)

Built with the stage 4b compiler as builder (sha1 de6b6bed...); the new compiler is sha1 8aed57ea.... The runtime
assembles. The 12-suite gate: no `.scout` differences, no golden mismatches outside the traits units, no faults, no
link or compile failures. 386 assembly goldens refreshed by copying `.sams` (rule), confirmed with cmp. The 13
`traits/` units are left alone.

## 5. Stage 4d: spawn and restart into the child's base, the row spec buffer (2026-10-31, source only)

Design §5.4 (decision 15 plain spawn, decision 11 / Q14 supervised children), §5.5 row "spawn / restart state",
§11.1 row 4; Phase4_prep §2 rows 1-3, 14, 15. Mac tree only; nothing built or run (Haiku builds, Sonnet reads).

### 5.1 Before 4d (read 2026-10-31)

* **Plain spawn, emitter** (`prims_actors.silica`). Every spawn form (`emit_spawn` for `spawn`, `spawn_dangerous`,
  `spawn_device`; `emit_spawn_registered` for the three registered forms; `emit_spawn_linked`) runs
  `spawn_promote_init_x11` (or `spawn_promote_init_reg(term, "X9", "X10")` for the 3-arg `spawn_linked`) first and
  then loads the root-word descriptor of the initial state's type from `spawn_state_desc_asm` (`L_sd_<fn>_<node>_0`,
  `ev_site_descriptor_rodata`) into X6 (X7 for `spawn_linked`), or `MOV X6, XZR` for a scalar or undescribed type.
  `spawn_promote_init_x11` emits NOTHING for a described type since phase 3b (`spawn_state_described`: non-scalar
  and `ev_type_described`); for an undescribed composite (a type parameter, a trait type) it still emits
  `spawn_init_move_asm` = `heap_promote_stack_aggregate_x0(nb)` (`BL _silica_rt_region_alloc` + a word copy of the
  shell, `nb` from `spawn_init_move_bytes`), parking X10 around it. ABI: X0 init, X1 beh, W2 core, X3 trampoline,
  X4 stack policy, X6 descriptor (`_silica_rt_actor_spawn[_dangerous]`); X0-X4, X6 dangerous, X7 descriptor
  (`_silica_rt_actor_spawn_linked`, `LBBsl_common`).
* **Plain spawn, runtime** (`prims_actors_runtime_asm.silica`). `_silica_rt_actor_spawn` (X27 = X6) and
  `LBBsl_common` (X27 = X7) call `_silica_rt_actor_stack_reserve` and then `_silica_rt_state_install(acb, init,
  desc)` (`prims_actors_state_asm.silica`: store the value at ACB #0; when `desc != 0` and the value is a pointer,
  `_silica_rt_state_measure`, `_silica_rt_state_alloc` of the measure rounded to 16 (this commits the header's
  chunk and sets #528/#568), `_silica_rt_state_copy` with the per-slot tables (P5), the copy's root at ACB #0); 1
  -> `LBB0_state_failed` / `LBBsl_state_failed` -> `_silica_rt_spawn_state_too_large` (decision 39). So the 5.4
  copy into the child's base, `#528/#568/#0`, the first-page commit and the state-too-large failure were already in
  place from phase 3b; what differs from the design's text is WHO copies (the runtime inside the spawn, with the
  phase-3 state copier, not emitted code with `L_mc_root`; Phase3_notes §10.2/§10.3) and the heap promote that
  precedes the spawn for an undescribed state.
* **Supervised children.** `term_child_spec@emit_child_spec_hidden_trampoline_store` writes the spec's hidden words:
  the trampoline at 72 and, since 3b, the state descriptor at 80 (`L_sdc_<fn>_<node>_0`, 0 for a scalar or
  undescribed `initial_state` / `start.0` type; `child_spec_state_type`). `_silica_rt_supervisor_materialize_init_
  children` and `_silica_rt_supervisor_start_child_in` (`prims_actors_child_table_asm.silica`; `add_child` enters
  the latter) copy the spec's words into a 144 B row node (`calloc` in `_silica_rt_child_table_ensure_min_cap`):
  `+24` = start.0 AS THE SPEC HELD IT (a pointer into the init list's cell or the `start_child` caller's record or
  heap), `+128` the state policy (spec 64), `+136` the descriptor (spec 80). `_silica_rt_actor_spawn_linked_row`
  loads X7 from the row's `+136` and `_silica_rt_supervisor_spawn_child_row_by_flavor` passes `+24` as X0, so
  every start and restart (`_silica_rt_supervisor_respawn_row` -> `spawn_child_row_by_flavor`) copied from the
  spec's own `start.0`: the lifetime hazard of design §5.4 / Phase3_notes §10.4 ("the row still points at the
  supervisor's own copy of start.0"). Rows are never removed singly: a tombstone (`+0` = 0) is reused by the next
  `start_child` (`Lsc_use_reuse_row`) and may be respawned by a `:one_for_all` `restart_child`
  (`Lsrestart_ofa_spawn_loop` respawns every row); all rows are freed at once by `_silica_rt_sb_unref` when the
  supervision block's last holder lets go.

### 5.2 What 4d does

* **The row spec buffer** (`prims_actors_child_table_asm.silica`). Row nodes grow 144 -> 160 B (`mov w1, #160` in
  `_silica_rt_child_table_ensure_min_cap`; header comment): `+144` = the spec buffer block (0 = none), `+152`
  spare. New `child_table_row_spec_buffer_asm(row, pfx)` emits, after the row's words are stored and before
  `spawn_child_row_by_flavor`, at both filling sites (materialize: `x28`, labels `Lmat_spec_*`; start_child:
  `x27`, `Lsc_spec_*`): free the row's earlier block if any (a reused tombstone) and clear `+144`; when `+136` is
  not 0, `X0 = [row+24]; X1 = [row+136]; BL _silica_rt_message_buffer; [row+24] = X0; [row+144] = X2`. The
  buffer is a flat (one-table) copy of the spec's initial state made by the 4a routine (a value below 65536 or a
  measure of 0 comes back as given with X2 = 0, so a scalar, an atom alternative or a literal string stays inline;
  no memory fails the current actor through `_silica_rt_region_alloc_failed`, as a send does). Every start and
  restart then copies from the row's buffer into the new child's state area through `_silica_rt_state_install`
  (per-slot tables), exactly as a plain spawn copies from the spawner's value: design §5.5's "measure + copy (2),
  1 copy into the child's base, 0 allocation" per start, plus one `malloc` per row lifetime. `_silica_rt_sb_unref`
  frees `+144` before each row node (`Lsbu_free_row_node`). Spawn argument order and ABIs are unchanged;
  `_silica_rt_actor_spawn_linked_row` still reads X7 from `+136`.
* **Layouts now used.** Child spec record (emitted, `child_spec_field_abi_offset`): shape 0, id 8, agent_type 16,
  initial_state / start.0 24, behavior / start.1 32, restart 40, shutdown 48, flavor 56, state_policy 64, hidden
  trampoline 72, hidden state descriptor 80 (unchanged by 4d). Row node (160 B): payload `+0..+72` as before,
  `+80` next, `+88` SB, `+96/+104` spawner record, `+112` identity, `+120` parked carriers, `+128` state policy,
  `+136` state descriptor, `+144` spec buffer block (NEW), `+152` spare. State descriptor: the root-word form
  `.quad 1, -1; .quad KIND, AUX` (`ev_site_descriptor_rodata`), the same form the casts, replies and plain spawns
  hand the copier.
* **Plain spawn.** No code change: the 3b runtime path IS the 5.4 copy (above). Comments in
  `prims_actors.silica` (`spawn_promote_init_x11`) record the 4e dependency.

### 5.3 Deferred to 4e, and why

* **`spawn_init_move_asm` / `heap_promote_stack_aggregate_x0` on the spawn path** (Phase4_prep rows 1-3): kept for
  an UNDESCRIBED composite initial state (a type parameter, a trait type). The descriptors cannot measure such a
  value, so `_silica_rt_state_install` stores the pointer as given; without the one-level promote the child would
  keep a pointer into the spawner's frame. The promote is the spawn path's last `_silica_rt_region_alloc` call and
  sets ACB #600 in the spawner (4a's retain rule). It goes in 4e with the heap, when an undescribed state gets a
  destination of its own (or when Q19 enforcement makes every state describable). The same gap holds for a row
  child whose `start.0` type is undescribed: `+136` = 0, no buffer, `+24` stays the spec's pointer (the pre-4d
  hazard, now confined to that case).
* `module_uses_message_copy` still counts a spawn as a copy site (Phase3_notes §10.4); harmless, goes with
  `L_mc_root` in 4e.
* The board (`rt_supervisors.S:408-505`) is phase 9.

### 5.4 Decisions taken here

1. The buffer holds `start.0` only, not the whole spec: every other spec word (atoms, the behaviour pointer, the
   shutdown integer, the hidden words) is already copied by value into the row, so the "spec's measured size" of
   design §5.4 reduces to the initial state's measure.
2. The 4a `_silica_rt_message_buffer` is reused (flat table), not a new state-area routine: the buffer is an
   intermediate source; the per-slot split (P5) happens in `_silica_rt_state_install` at each start.
3. Freed on reuse and at `sb_unref`, never at tombstoning: a tombstoned row can still be respawned
   (`:one_for_all` restart_child walks every row), so its source must outlive the tombstone.
4. The block word is `+144`, not a repurposed payload word: the payload layout is read by the lowering's row
   walkers (`which_children`, `get_child`) and by the board port.

### 5.5 Not verified (Haiku builds, Sonnet reads)

Nothing built or run. Expected drift: `__silica_runtime` `.ascomp` only (the row size, the two buffer blocks, the
free in `sb_unref`); no user-module `.ascomp` should move (no emitter output changed; comments only in
`prims_actors.silica`). `.sout` must equal `.scout` everywhere. Where to look: `supervisors_addition`
(`add_child_record_initial_state`, `supervisor_child_tuple_state`, every restart trial, `which_children` after
restarts), `supervisors_*` with `:one_for_all` / `:rest_for_one`, `record_shapes_actors_addition`, the compiler
building itself (its pipeline actor is a plain spawn: unaffected). Risks judged highest: (a) the `Lmat` labels
must not collide with another site in the runtime unit (grep found none); (b) `_silica_rt_message_buffer` fails the
CURRENT actor on no memory, which in `start_child` from `add_child` is the calling actor, not the supervisor; (c)
a spec whose `start.0` is a described type that the type checker lets through with an unbound `rec` (Q19 not yet
enforced) measures through KIND 0 words as before, no new behaviour. Not checked: whether any trial compares a
restarted child's state identity with the spec's (it would now differ, as it already did after 3b's copy).

## 5b. Stage 4d: gate result (2026-10-31)

Built with the stage 4c compiler as builder (sha1 8aed57ea...); the new compiler is sha1 07718d46.... The runtime
assembles. The 12-suite gate: no `.scout` differences, no golden mismatches, no faults, no compilation or link
failures. The only drift is 13 `traits/` units in supervisors_addition, which are left alone. No golden copies.

## 6. Stage 4e: the implicit heap removed (2026-10-31, source only)

Design §9 (9.1 emitted code, 9.2 the front end, 9.4), §5.1, §11.1 row 4; Phase4_prep §2 rows 1-3, 6-11,
16-22, U1 and the `heap_used()` paragraph; the deferrals of §3.3, §4.3 and §5.3 above. Mac tree only;
nothing built or run (Haiku builds, Sonnet reads). The Linux twins, src_selfhost and the ESP32-S3 (§9.3,
phase 9) are untouched.

### 6.1 Before 4e: every heap use on the Mac tree (read 2026-10-31)

Grep used for the counts (comments included, `_silica_rt_region_alloc_failed` excluded: it is the failure
entry, not an allocation):
`grep -rn '_silica_rt_region_alloc\b\|_silica_rt_region_alloc_in\|heap_promote\|_silica_rt_heap_in_use\|_silica_rt_actor_init_region\|_silica_rt_actor_dealloc_region\|_silica_rt_region_list\|_silica_rt_region_mark\|_silica_rt_region_release_to\|_silica_rt_region_destroy\|L_ev_heap\|L_ev_region_alloc\|L_mc_\|L_stack_top\|#160\]\|#184\]' --include='*.silica' compiler/src/emitter/apple_silicon_mac | grep -v '\.bak' | grep -v _silica_rt_region_alloc_failed`
gave **173 lines** (term_message_copy 58, prims_actors_runtime_asm 65, prims_actors 20, prims_memory 13,
prims_actors_child_table_asm 7, emitter_core 2, prims_list 2, prims_actors_state_asm 2, and one comment
each in ffi_fault_runtime_asm, term_emit_kind_compound_part2/part3, term_reg_spill, prims_actors_stack_asm).
Code sites, by file (`compiler/src/emitter/apple_silicon_mac/`):

| # | File : line | Function / label | What it does |
| --- | --- | --- | --- |
| E1 | `terms/prims/prims_actors.silica:285, 297` | `heap_promote_copy_words`, `heap_promote_stack_aggregate_x0` | `BL _silica_rt_region_alloc` plus a word copy of a shell (the one-level promote) |
| E2 | `prims_actors.silica:439-492` | `spawn_promote_init_x11`, `spawn_promote_init_reg`, `spawn_init_move_asm` (with `spawn_init_move_bytes`, `spawn_init_needs_heap_copy` 280, `spawn_init_stack_bytes` 262) | an UNDESCRIBED composite initial state promoted one level before the spawn (every spawn form, 932/954 and spawn_linked) |
| E3 | `prims_actors.silica:580, 596, 765` | `heap_promote_reply_x0` (`_silica_rt_region_alloc_in`, the caller's arena), `bmv_reply_asm`, the undescribed arm of `behaviour_result_move_asm` | an undescribed composite reply promoted into the caller's arena, or deep-copied there by `L_mc_root` (`md_reply_copy_asm`) |
| E4 | `prims_actors.silica:684, 668` | `bmv_state_undescribed_asm`; the ACB #600 store in `bmv_state_asm` | an undescribed composite new state promoted one level to the actor's heap; #600 set so the buffer is kept |
| E5 | `prims_actors.silica:722, 811, 901` | `stack_value_to_heap_asm` (`L_stack_top`, `L_ev_heap`), `send_deep_copy_asm` (the timer: `L_mc_root` through `md_copy_call_asm`, the `\|mv` / `\|_mva` elisions), `actor_message_copy_x10` (every send, cast, call and timer site 1046-1094, 1228) | the timer's message walked to the heap and deep-copied there; an undescribed message promoted one level at every site |
| E6 | `prims_actors.silica:1167` | `runtime_label("heap_used")` | the `heap_used()` builtin -> `_silica_rt_heap_used` |
| E7 | `terms/term_message_copy.silica:1209-1346` | `mc_h_root` .. `mc_h_measure_list_str`, `emit_message_copy_helper` | `L_mc_root` and its helpers: `L_mc_alloc_shell` (`_silica_rt_region_alloc[_in]`), `L_mc_new_region` (`_silica_rt_raw_alloc`), `L_mc_reserve` (`L_region_grow`), `L_mc_is_canonical` (the canonical arena table), `L_mc_premap/map_region`, the walkers, `L_mc_measure` |
| E8 | `term_message_copy.silica:1197, 1152, 721, 730, 945, 1141, 1125` | `module_uses_message_copy`, `md_reply_copy_asm`, `md_copy_call_asm`, `md_prim_value_is_move`, `mc_elided_sites`, `md_site_arena_elided`, the `\|_mva` marker in `fn_copy_markers` | the gate that appends `L_mc_root`, the undescribed reply copy, the copy call, the arena-copy elisions |
| E9 | `terms/prims/prims_memory.silica:720-740, 746, 757` | `emit_evacuation_helper` (`L_ev_heap`, `L_ev_heap_shell`, `Lw_copy_heap`, `Lev_heap_done`..`Lev_hr_done`), `emit_ev_region_alloc` (`L_ev_region_alloc: B _silica_rt_region_alloc`, U1), `emit_stack_top_helper` (`L_stack_top`) | the heap mode of the phase-2 evacuation routine and its allocator; the walk's upper bound |
| E10 | `terms/prims/prims_list.silica:827` | `emit_region_alloc_stub` | the malloc forwarder `_silica_rt_region_alloc` with `_silica_rt_region_list/mark/release_to` for programs without the actor runtime |
| E11 | `emitter_core.silica:232-240, 248, 252, 374-392, 416, 142-181, 2508, 2961` | `needs_message_copy` / `emit_message_copy_helper`, `stack_top_helper`, `emit_ev_region_alloc`, `region_alloc_stub` and its predicates (`aggregate_return_heap_stub_*`, `term_has_aggregate_stack_let`, `module_needs_region_alloc_for_aggregate_copy`), `module_emits_region_runtime` (no caller), the `md_reply_copy_asm` argument of `behaviour_result_move_asm` | the module-level gates |
| R1 | `terms/prims/prims_actors_runtime_asm.silica:237, 500` | `_silica_rt_actor_spawn`, `LBBsl_common` | `bl _silica_rt_actor_init_region` |
| R2 | `prims_actors_runtime_asm.silica:1174, 6658, 6772, 7106`; `prims_actors_stack_asm.silica:1010`; `ffi_fault_runtime_asm.silica:714` | the actor exit paths (`LBB1_exit`, badarith, case_clause, name_taken, `Lafc_stack_done`, `L_gff_keep_stack`) | `bl _silica_rt_actor_dealloc_region` |
| R3 | `prims_actors_runtime_asm.silica:2027, 3091, 3105, 3159, 3172, 3236` | `_silica_rt_get_cpu_topology` (the core array), `_silica_rt_build_int_range_list` (chunk, handle), `_silica_rt_build_list_from_words` (chunk, handle), `_silica_rt_cstr_to_string` (header) | runtime-built lists and strings in the heap (reached from the prims get_cpu_topology, get_efficiency_cores, get_performance_cores, get_core_capabilities through `_silica_rt_apple_hw_optional_caps_list` 3252 and `_silica_rt_apple_build_cache_levels` 3396; the records beside them are `_malloc`) |
| R4 | `prims_actors_child_table_asm.silica:1691, 1718, 1904, 1918, 1938` | `_silica_rt_supervisor_get_child_info_acb` (record, empty record), `_silica_rt_supervisor_which_children_acb` (record, 56 B chunk, handle) | supervisor query results in the heap |
| R5 | `prims_actors_runtime_asm.silica:3736, 3749` | `_silica_rt_actor_init_region`, `_silica_rt_actor_dealloc_region` | ACB #160/#168/#176/#184 zeroed; the block chain unmapped and `_silica_rt_heap_in_use` decremented |
| R6 | `prims_actors_runtime_asm.silica:3967, 3981` | `_silica_rt_region_alloc_in`, `_silica_rt_region_alloc` | the allocator: ACB #176/#184 bump, 64 MB `mmap` blocks chained at #160 (#168 bytes mapped), `_silica_rt_heap_in_use`, ACB #600 set (4002), the `main` fallback (`_malloc` onto `_silica_rt_region_list`) |
| R7 | `prims_actors_runtime_asm.silica:4103` | `_silica_rt_heap_used` | `ldar _silica_rt_heap_in_use` |
| R8 | `prims_actors_runtime_asm.silica:4152, 4198, 4204, 4231, 4233` | `_silica_rt_region_destroy` (no caller; scans the canonical table), `_silica_rt_region_mark`, `_silica_rt_region_release_to`, `.comm _silica_rt_region_list`, `.comm _silica_rt_heap_in_use` | the rest of the heap's symbols |
| R9 | `prims_actors_runtime_asm.silica:4935-4937, 4980-4982`; `prims_actors_child_table_asm.silica:2510-2512, 2535-2537` | `_silica_rt_report_begin` / `_release`, `_silica_rt_owned_record_begin` / `_release` | read ACB #160/#176 as an arena-span snapshot to decide whether a behaviour kept an owned report |
| R10 | `prims_actors_runtime_asm.silica:820, 1022, 1080, 1508`; `prims_actors_state_asm.silica:443`; `prims_actors.silica:668` | the dispatch start (clear), `LBB1_reply_drain_done`, `LBB1_free_user`, `LBBsigpend_active_user`, `_silica_rt_message_forward` (read); `bmv_state_asm` and `_silica_rt_region_alloc` (set) | ACB #600, the retain flag |

Not heap, left alone: `_silica_rt_raw_alloc` (4133: the explicit `alloc_region` block of an atomic or device
region, `prims_memory@emit_alloc_region`, and `L_region_grow`), `L_region_grow` / `_silica_rt_region_lock` /
`canonical_arena_runtime_asm` (the family arenas, phase 5), `_silica_rt_region_alloc_failed`
(prims_actors_stack_asm:1195, the `(:explicit, :region_alloc_failed)` entry the mailbox buffer and
`alloc_region` still use). Phase4_prep's unverified `#168/#176` reads: the runtime's at 1036/1452/1675/1760
are a call record's `+160/+168` (bytes, holders), the carrier's at 646/698/2072/2115 are carrier-block queue
words; none is an ACB heap word.

### 6.2 What 4e does (Mac source, 2026-10-31; nothing built or run)

Order of work: the undescribed spawn / reply / state / message paths first, then the runtime's builders,
then the front end (nothing to do, 6.4), then the heap itself. After the change the grep of 6.1 gives
**43 lines**, every one a comment, a call record's `+160` (prims_actors_runtime_asm 1757, state_asm 538),
the evacuation routine's own `[X29, #160]` frame slot (prims_memory ev4) or the cache-levels frame slot
`[x29, #160]` added here; **no code line calls `_silica_rt_region_alloc[_in]`, reads or writes ACB
#160..#184, `_silica_rt_heap_in_use` or `_silica_rt_region_list`, or enters `L_ev_heap` / `L_mc_root`**.

* **One rule for every actor boundary** (`prims_actors.silica`, `term_child_spec.silica`,
  `term_message_copy.silica`). New `term_message_copy@ev_type_has_node_root(t)` = `md_root_needs_descriptor`
  (the root is a ref, record, tuple, sum, buffer, list or string: kinds 2 to 8). It replaces
  `ev_type_described` as the gate at `send_buffer_copy_asm` (every send, cast, call and now the timer),
  `behaviour_result_move_asm`'s reply arm, `bmv_state_asm`, `spawn_state_described` (every spawn form and
  `spawn_linked`) and `emit_child_spec_state_descriptor_word` (the row spec buffer). A type the descriptors
  cannot follow to every word (a type parameter, a trait type inside a record, tuple or sum) now gets the
  same root-word descriptor a described one gets: `mc_entry` already spells an unknown word as a scalar
  entry (`.quad 0, 0`), so the runtime copier copies the known structure and carries the unknown words as
  they are, which is exactly what the one-level shell promote to the heap did for every word, with the
  copy going where the design puts it: the mailbox buffer (§5.1), the caller's stack (§5.3), the child's
  state area (§5.4), the state area at dispatch end (§4.3). Deleted: `heap_promote_copy_words`,
  `heap_promote_stack_aggregate_x0`, `spawn_promote_init_x11/_reg`, `spawn_init_move_asm/_bytes/_scalar_alt`,
  `spawn_init_needs_heap_copy`, `spawn_init_stack_bytes/_round16`, `shell_move_bytes`, `composite_move_*`,
  `sum_alts_*`, `top_level_bar_from`, `max_int64`, `heap_promote_reply_x0`, `bmv_reply_asm`,
  `bmv_state_undescribed_asm`, `stack_value_to_heap_asm`, `send_deep_copy_asm`, `aggregate_message_type_bytes`,
  `actor_message_copy_bytes`, `actor_message_copy_x10`, `timer_release_thunk_asm`; `bmv_state_asm` lost
  `soff`, `behaviour_result_move_asm` lost `reply_copy` (emitter_core 2961 updated). ACB #600 is still set
  by `bmv_state_asm`, now only when `ev_type_described(stype)` is false (6.3 item 2).
* **The timer** (`emit_timer_cast`, `prims_actors_timer_asm.silica`): `timer_cast` takes
  `send_buffer_copy_asm` like a cast and passes X2 = bytes, X3 = block to `_silica_rt_timer_prepare`,
  which keeps them in the record (#32 the block, where the always-0 release thunk was; #48 the bytes).
  `_silica_rt_timer_fire` casts through `_silica_rt_actor_cast_flagged_buffered` with those words: a
  delivered message's node owns the block, a dropped one is freed by `LBB3_dropped`, so the fire frees
  only the record. `_silica_rt_timer_release` (cancel, a dead target at send_after) frees block and record.
  A failed `calloc` in prepare frees the block.
* **`term_message_copy.silica`**: `L_mc_root` and every helper (`mc_h_root` .. `mc_h_measure_list_str`,
  `emit_message_copy_helper`), `module_uses_message_copy` and its gate, `md_reply_copy_asm`,
  `md_copy_call_asm`, `md_prim_value_is_move`, `mc_elided_sites`, `md_site_arena_elided` and the `|_mva`
  marker are deleted; `fn_copy_markers` writes `|_mvs` only; exports updated. `md_type_needs_copy`,
  `md_descriptor_rodata`, `md_site_label`, `mc_site_is_last_use` stay (unused, harmless). The header's
  description of L_mc_root is kept as the specification of the descriptor format (a note at line 111).
* **`prims_memory.silica`**: the evacuation routine keeps frame mode only (`L_ev_frame`); `L_ev_heap`,
  `L_ev_heap_shell`, the shell-root block, `Lw_copy_heap`, `Lev_heap_done..Lev_hr_done` and the X22 mode
  flag are gone (X22 is still saved, now always 0); `emit_ev_region_alloc` (U1) and `emit_stack_top_helper`
  deleted with their exports. `prims_list@emit_region_alloc_stub` deleted. `emitter_core`: the message-copy
  helper, the stack-top helper, `L_ev_region_alloc` and the malloc stub are no longer appended; the stub's
  predicates (`aggregate_return_heap_stub_*`, `term_has_aggregate_stack_let`,
  `module_needs_region_alloc_for_aggregate_copy`) and the dead `module_emits_region_runtime` deleted.
* **The runtime builders** (`prims_actors_runtime_asm.silica`, `prims_actors_child_table_asm.silica`;
  design §9.1 rows for `get_cpu_topology`, `_silica_rt_build_int_range_list`, `_silica_rt_build_list_from_words`,
  `_silica_rt_cstr_to_string`, `get_child_info`, `which_children`). New leaf `_silica_rt_dest_take(X0 = a
  destination pair {next free (grows down), floor}, X1 = bytes) -> X0 = a zeroed 8-byte-aligned block`;
  an overrun aborts through the new `_silica_rt_abort_dest_take` (ffi_fault_runtime_asm, status 71).
  `_silica_rt_build_int_range_list(X0, X1, X2 = pair)`, `_silica_rt_build_list_from_words(X0, X1, X2 = pair)`,
  `_silica_rt_cstr_to_string(X0, X1 = pair)`, `_silica_rt_apple_hw_optional_caps_list(X0 = pair)`,
  `_silica_rt_apple_build_cache_levels(X0..X3, X4 = pair, kept at [x29, #160]; L_bc_push takes X6)` take
  every block from the pair; the `_malloc` records of the topology (core_info, numa, memory range, the
  topology record, the cache-level records and the cache_info wrapper, the capabilities sentinel) come from
  it too. Each entry an emitted prim calls reserves a destination area in the dynamic part of its own frame
  and keeps the pair in its frame: `_silica_rt_get_cpu_topology` 256 bytes per core + 2048 at `[x29, #96]`
  (frame 96 -> 112), `_silica_rt_get_core_capabilities` 400 bytes at `[x29, #96]` (96 -> 112),
  `_silica_rt_get_efficiency_cores` / `_performance_cores` 24 + 32 * ((n + 1) / 2) + slack at `[x29, #16]`
  (frames 48 -> 64 and 32 -> 48; count <= 0 answers 0 with SP intact),
  `_silica_rt_supervisor_which_children_acb` 120 bytes per live row (counted first) at `[x29, #16]` (96 ->
  112; no row answers 0 with SP intact), `_silica_rt_supervisor_get_child_info_acb` a 48-byte push. On
  success each lowers SP to the lowest block (the cursor rounded down to 16) and leaves through X29
  (callee-saved registers restored X29-relative), as `_silica_rt_actor_call` does for a reply since 4c;
  `_silica_rt_sup_ref_call` restores its registers X29-relative and pops its own frame only when the body
  kept SP (`SP == X29` after the body), otherwise passes the lowered SP on. The emitter
  (`prims_actors@runtime_call_asm`, used by `emit_runtime_nullary/unary/binary` for the six prims) emits
  `MOV X16, SP; STR X16, [X29, #24]; BL <entry>; BL L_adopt`, the sequence of an actor call site, so the
  value becomes the bottom of the calling frame's dynamic part and pops with it.
* **The heap** (`prims_actors_runtime_asm.silica`): `_silica_rt_actor_init_region` (and its two calls in
  the spawn paths), `_silica_rt_actor_dealloc_region` (and its six calls: four exit paths here,
  `prims_actors_stack_asm` `Lafc_stack_done`, `ffi_fault_runtime_asm` `L_gff_keep_stack`),
  `_silica_rt_region_alloc_in`, `_silica_rt_region_alloc`, `_silica_rt_region_destroy`,
  `_silica_rt_region_mark`, `_silica_rt_region_release_to`, `.comm _silica_rt_region_list` and
  `.comm _silica_rt_heap_in_use` deleted. `_silica_rt_heap_used` answers 0 (6.3 item 3).
  `_silica_rt_report_begin` / `_release` and `_silica_rt_owned_record_begin` / `_release` no longer read
  ACB #160/#176: the arena-span scan that decided whether a behaviour kept an owned report is replaced by
  the ACB #600 test (keep when the behaviour returned an undescribed state; 6.3 item 2); `owned_record_begin`
  clears node +40/+48. `_silica_rt_raw_alloc`, `L_region_grow`, `_silica_rt_region_lock` and
  `canonical_arena_runtime_asm` stay (explicit atomic/device region blocks; the family arenas are phase 5);
  `_silica_rt_region_alloc_failed` stays as the failure entry. Comments at the ACB header, the dispatch
  start, `LBB1_reply_drain_done`, `LBB1_free_user`, `LBBsigpend_active_user` and `_silica_rt_actor_cast_flagged`
  updated.

### 6.3 Decisions taken here

1. **Undescribed composites take the ordinary descriptor** (design §9 does not name a destination for a
   type parameter or trait type; §5.1/5.3/5.4 assume a descriptor). The descriptor builder's scalar entry
   for an unknown word makes the runtime copier's copy a superset of the one-level shell promote (the
   known structure copied, every unknown word carried verbatim), so the destination is the design's for
   every boundary and no heap call stays behind for this case. A bare type parameter, a function value and
   a region witness have no node root and travel as a word, as before. Nested known records inside an
   undescribed type are now copied deeper than the shell promote copied them (identity differences only).
2. **ACB #600 stays** (design: "goes with the implicit heap in 4e/phase 5") as the retain rule for a
   behaviour whose state type `ev_type_described` rejects: such a state is copied into the state area
   through its descriptor, but a word the copier carried as it is may still point into the mailbox buffer
   or an owned report, so the buffer is kept (LBB1_free_user) and the report kept
   (`_silica_rt_report_release`, `_silica_rt_owned_record_release`), the one leak the shell promote also
   had. It goes when Q19 / phase 5 make every state describable.
3. **`heap_used()` answers 0** on the hosted targets (Phase4_prep §2 names this a Lee decision: remove or
   redefine). Checked against the 17 hosted trials that call it: every `.scout` prints a zero growth, a
   `>= 0` flag or a value the builtin does not reach (`heap_used_reports_bytes` prints `1 0 8 0`: `h0 >= 0`,
   `h1 > h0` already false since 3b, the reply); `workers_two_field_record_return_at_arena_block_end`
   polls `released` up to 100,000 times and discards the result, as it already did. No `.scout` changes.
4. **Frame residency through adoption, not a sizing call per site** for the runtime builders. §9.1 says
   "a destination block the emitted call site allocates after a sizing call"; the topology cannot be
   sized without computing it twice, so each entry reserves a bounded area in its own frame, builds down
   from its top, and returns with SP at the lowest block for the call site to adopt: the value lands in
   the calling actor's frame, which is §9.1's destination, by §3.3's stack form of destination-passing
   and the mechanism 4c already uses for replies. The unused part of the reserve is released before the
   leave; the entries' dead fixed frames are adopted garbage, as a callee's fixed part is after any
   adoption.
5. **The topology's `_malloc` records are moved into the destination too** (§9.1 names the lists and
   strings; a record pointing at frame-resident lists while itself leaking in malloc would be half of
   each). `_silica_rt_dest_take` zeroes every block it hands out because the arena memory it replaces was
   fresh `mmap` memory read as zero (the 56-byte which_children chunk's +40, a half-full chunk's free slot).

### 6.4 The front end (design §9.2)

Nothing changed. §9.2's four rows are the `canonical_arena_lookup` synthesis for collection constructors,
the builtin lists naming `canonical_arena_*` and `ref_in_region`, the `moved_region` rebinding at spawn
and E2100's region meaning: by §11.1 they are phase 5 (the family arenas, with the stdlib field) and
phase 6 (the region checker), and the emitter reads none of them for an implicit-heap decision (the `|mv`
tag the SIR writes stays for the region checker; `|_mva` was emitter-internal and is gone). The task's
"only where §9.2 requires it on the Mac" therefore requires nothing here; the canonical arena runtime and
`emit_canonical_arena_lookup` stay until phase 5.

### 6.5 Open questions (none block the stage)

* `heap_used()`'s replacement measure (6.3 item 3; design §9.4: stack depth and state-area size): Lee.
* The destination bounds (256 bytes per core + 2048; 400; 120 per row) are derived from the layouts and
  written beside each reservation; an overrun aborts with "a runtime builder overran its destination area"
  rather than overrunning a frame. Should a platform ever report more than 8 optional capability flags or
  more than 8 cache levels, the caps-list and level arrays (8 words, pre-existing) bound them first.
* `module_uses_alloc_region` (prims_memory) and `md_type_needs_copy`, `md_descriptor_rodata`,
  `md_site_label`, `mc_site_is_last_use` (term_message_copy) are now uncalled on the Mac; left for the
  Linux twins (phase 8) and deleted then.

### 6.6 Not verified (Haiku builds, Sonnet reads)

Nothing built or run. Expected drift: `__silica_runtime` `.ascomp` in every unit (the builders, the six
entries, `_silica_rt_sup_ref_call`, the deleted heap routines, the timer); every user-module `.ascomp`
(the evacuation helper lost its heap mode, `L_stack_top` and `L_ev_region_alloc` are gone, modules that
copied lost `L_mc_root`); every module with a `get_cpu_topology`, `get_efficiency_cores`,
`get_performance_cores`, `get_core_capabilities`, `which_children`, `get_child_info` or `timer_cast` site
(the pre-call SP store, `L_adopt`, the buffer words); every behaviour whose state or reply type was
undescribed (new `L_std_` / `L_evb_` rodata, no promote). `.sout` must equal `.scout` everywhere. Where to
look: `cpu_discovery_and_spawn_pinning` (the adopted topology and core lists: `length`, field loads,
`cpu_topology_x28_live_across_capabilities`), `supervisors_*` (`which_children` after restarts,
`get_child_info`, call_supervisor paths through `_silica_rt_sup_ref_call` whose bodies keep SP),
`timers_addition` (a buffered timer message; cancel frees block and record), `actors_addition`
(`heap_used_reports_bytes`, the `*_no_heap_growth` and `zero_heap_growth_*` trials now print the constant
0 path), `carriers_addition/workers_two_field_record_return_at_arena_block_end` (100,000 polls),
`region_hazards_open_addition`, every suite with a generic (type-parameter) behaviour state or message.
Risks judged highest: (a) `L_adopt` after a runtime prim in a frame whose transient area holds an sret
slab (the same situation as after an actor call, not new); (b) the X29-relative leaves of the six entries
and `_silica_rt_sup_ref_call` (a wrong offset corrupts a callee-saved register of the caller; every offset
was derived from the prologue beside it); (c) the topology bound; (d) a trial comparing a timer message's
identity with the sender's (now a copy, as a cast's is since 4a). Not checked: that no runtime path
reads the timer record's #32 as a thunk (grep found `_silica_rt_timer_release` only).

## 6b. Stage 4e: gate result and phase 4 close (2026-10-31)

Builds: 4e with the export fix (ab8dc890...), then with the tuple-literal message fix and state_area_bytes (c4721975...).
The 12-suite gate on c4721975: zero `.scout` differences, zero golden mismatches, zero faults, compile or link
failures; the two earlier output failures (tuple_message_casts_hold_state, supervisor_init_in_other_unit) pass.
Assembly goldens refreshed by copying `.sams` (rule), 3997 plus the ordered_data_structures set, confirmed with cmp.
The 13 `traits/` units are left alone. heap_used() is retired; state_area_bytes() replaces it (one function, reads
ACB #568). Stack depth stays with get_actor_memory_usage. Trials rewritten to state_area_bytes; four checks now
pass trivially (thousand_actors_at_rest, init_failure_frees_acb, supervisor_end_frees_child_table,
failure_reports_free_heap) and the carriers released() poll cannot see its drop: flagged for a rewrite (not done).

Phase 4 is complete on the Mac tree. Linux and ESP32 ports come after phase 7.
2026-11-01: superseded: alloc_region is a frame area (Lee's decision); see chunk15 section 3.8.
