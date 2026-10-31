# Chunk 15 phase 4: preparation (messages, replies, spawn)

Design: [chunk15_stack_memory_design.md](chunk15_stack_memory_design.md) section 0, section 5 (5.1-5.5), 9.1, 11.1 row 4, 11.2, 11.3, 12, 13.
Written 2026-10-29 by reading and grep only. No source, trial or golden was touched; nothing was built or run.
Line numbers are from the working tree at this date (apple_silicon_mac unless stated) and WILL move; re-grep before editing.

## 1. Dependency and status

Phase 4 builds on phase 3 (state at the base, dispatch end, `retire`, `state_policy`). Phase 3 is CLOSED by Lee
(2026-10-31; `Phase3_notes.md` section 1). The memory target and stage 3e (Linux ports) were removed from its completion
gate on 2026-10-30, so the gate is no longer a blocker. The phase 3 compiler is published as
`binaries/silica-999937-macos-applesilicon` (sha1 85f61850d62404af2b389a1acaacabab8fffa73e, reached through
`binaries/silica-compiler`; see `Phase3_notes.md` section 1; its goldens and the final gate run were recorded there as not
yet verified, and the seed is unchanged).

Still true after the closing, and relevant to phase 4 (`Phase3_stage2_analysis.md`): parse time and memory are quadratic in
the parser batch (5.0 GB at 90k tokens, 5.4 GB then exit 70 at 180k, stage-2 RSS figures) and the pass criterion in section 3
("Pass criterion") was never answered. These were not carried into the closed gate; they are phase 4 baselines, not
phase 3 blockers.

**Measurement convention (once, for the whole document).** "Physical footprint" is the vmmap `Physical footprint (peak)`
sampled about once a second by `programmer_tools/ram_profile_unit.sh`; its files are
`benchmarking/memory_use_reports/data/*.tsv`, column `peak_footprint_MB`. "RSS" is the peak resident set size from the
`time -l` style wrapper (the older `Phase3_stage2_analysis.md` figures); it excludes compressed and swapped pages and is NOT
comparable to footprint. Every number below is labelled with which one it is. Lee's 4 GB target is a footprint target.

This document prepares; it does not start phase 4. Phase 4 depends on phase 3
for: the state area at the child's base (5.4 copies the initial state into the area 3b/3c define), the ACB words and
`_silica_rt_stack_grow_to` from phase 0/3, and the per-slot copier tables (P5) that spawn/restart reuse.

## 2. Heap inventory (hosted targets)

What phase 4 removes: the implicit heap (`_silica_rt_region_alloc`, ACB #160..#184), the arena-based message copy, and
every heap promote on the send, reply and spawn paths (design 9.1, 11.1 row 4, "the implicit heap and
`_silica_rt_region_alloc` deleted on the hosted targets"). Files are under
`compiler/src/emitter/apple_silicon_mac/terms/` unless stated. The `linux_aarch64` and `linux_x86_64` trees carry
twins of the emitter-side items (same function names; lines differ by a few) and are ported after the Mac.

| # | File : line | Function / label | What it does today | Phase 4 replacement (design) |
| --- | --- | --- | --- | --- |
| 1 | `prims/prims_actors.silica:298` | `heap_promote_stack_aggregate_x0` | emits a `BL _silica_rt_region_alloc` plus word copy to move a frame aggregate into the current actor's arena (spawn init state, send operand) | deleted; spawn copies into the child's base, send into the mailbox buffer (5.1, 5.4) |
| 2 | `prims/prims_actors.silica:434` | `spawn_promote_init_x11` | promotes the spawn init state to the heap before the runtime spawn call | deleted; the spawner copies the state into the child's state area after `_silica_rt_actor_stack_reserve` (5.4) |
| 3 | `prims/prims_actors.silica:458` | `spawn_init_move_asm` | spawner copies the init state into its own arena and passes the pointer | `L_mc_measure`, `_silica_rt_stack_grow_to(child, ...)`, `L_mc_root` into `[top-1040-bytes, top-1040)`; child `#528/#568/#0` set (5.4) |
| 4 | `prims/prims_actors.silica:787` | `send_deep_copy_asm` | emits the type-directed deep copy of a message into the sender's arena | measure, `malloc(bytes)`, copy, store block at node `+8`, size at `+40` (5.1) |
| 5 | `prims/prims_actors.silica:816` | `actor_message_copy_x10` | copy-then-promote of the message operand (promotes via #1 when the operand is a frame aggregate) | same as 4; pointer-free one-word messages stay inline (5.1) |
| 6 | `prims/prims_actors.silica:559` | `heap_promote_reply_x0` | promotes a reply into the blocked caller's arena through `_silica_rt_region_alloc_in` (H4) | deleted; replier measures, `_silica_rt_stack_grow_to(caller_acb, dest)`, copies below the caller's parked SP (5.3) |
| 7 | `term_message_copy.silica:996` (`md_reply_copy_asm`), `:988` (`md_reply_elided`) | reply copy / `\|_mvr` | emits the reply copy; elides it when `\|_mvr=1` | `\|_mvr` removed; the reply always copies into the caller's stack (5.2, 5.3) |
| 8 | `term_message_copy.silica:1053-1081` | `mc_h_root`, `mc_h_premap`, `mc_h_map_region`, `mc_h_new_region`, `mc_h_reserve` (`L_mc_root`, `L_mc_premap`, `L_mc_map_region`, `L_mc_is_canonical`, `L_mc_new_region`, `L_mc_reserve`, `L_mc_alloc_shell`; the last two call `_silica_rt_region_alloc[_in]`, new_region calls `_silica_rt_raw_alloc`) | the copier: shells in an ACB arena, REGION words remapped to fresh regions | destination cursor into the buffer/stack/base; premap, map_region, is_canonical, new_region deleted; region words copied as is (5.1) |
| 9 | `term_message_copy.silica:1139-1175` (`mc_h_measure_*`), `:62` comment | `L_mc_measure` helpers (already present, partly built in phase 0) | measuring walk that gives the exact byte total | used by 4/5/6/3 so each destination is sized before the copy; KIND 7 LIST (whole chunks, claim words) and KIND 8 STRING get their entries (5.1) |
| 10 | `term_message_copy.silica:863` (`mc_site_is_last_use`), `:968` (`fn_copy_markers`), `:879` (`mc_elided_sites`) | `\|_mvs` / `\|_mvr` markers | mark sends whose operand is a last use, replies needing no copy | `\|_mvs` only when the operand is the whole message parameter and no part reaches new state; `\|_mvr` removed (5.2) |
| 11 | `term_message_copy.silica:659`, `:663` | `md_prim_value_is_move`, `md_prim_is_move_wrapper` | recognise `move(x)` so the copy is skipped | dead; removed; `move(x)` is copied like any send (5.1) |
| 12 | `prims/prims_actors_runtime_asm.silica:1101, 1169, 1189, 1359, 1400` | `_silica_rt_actor_send`, `_cast`, `_cast_flagged`, `_call`, `_call_acb` | mailbox node + arena pointer, caller parks in `call`; dead-actor path (`LBB3_dead_locked`) frees the node | node `+8` = malloc'd buffer, `+40` = byte count; dead target frees buffer with the node; call record 176 B, `reply_set` states 0..4 (5.1, 5.3) |
| 13 | `prims/prims_actors_runtime_asm.silica:1290` | `_silica_rt_actor_signal_pending_call_deaths` | walks pending mailbox at actor end, frees nodes | also frees each node's buffer: one `free` per pending message (decision 31, 5.1) |
| 14 | `prims/prims_actors_runtime_asm.silica:124, 301, 543` | `_silica_rt_actor_spawn`, `_spawn_linked`, `_spawn_linked_row` | store the arena init-state pointer (RT:151); reserve the child stack | reserve, then caller-emitted copy into the child base; spawn fails the spawner with `(:explicit, :state_too_large)` if the state does not fit (5.4, P11) |
| 15 | `prims/prims_actors_child_table_asm.silica:419`, `:116` | `_silica_rt_supervisor_spawn_child_row_by_flavor`, `_silica_rt_child_table_free` | restart starts a child from a spec that points into whatever arena built it (lifetime hazard) | row spec buffer (malloc'd, measured size) copied into each child's base; freed at row removal / table free (5.4, Q14) |
| 16 | `prims/prims_actors_runtime_asm.silica:3675, 3689` | `_silica_rt_region_alloc_in`, `_silica_rt_region_alloc` | the implicit heap: 64 MB chained actor arena, `main` fallback list | deleted with ACB #160..#184, `_silica_rt_actor_init_region`/`_dealloc_region` (3440-3504), `_silica_rt_region_destroy`; `_silica_rt_raw_alloc` stays only if FFI arena/registry need it (9.1) |
| 17 | `prims/prims_list.silica:826` | `emit_region_alloc_stub` | malloc forwarder for programs without the actor runtime | deleted with `_silica_rt_region_list/mark/release_to` (9.1) |
| 18 | `prims/prims_actors_runtime_asm.silica:1735` (via `_silica_rt_get_cpu_topology`) | core-list builder | allocates the returned list in the heap | destination block from the call site after a sizing call (9.1) |
| 19 | `prims/prims_actors_runtime_asm.silica:2799, 2813` | `_silica_rt_build_int_range_list` | builds a runtime list in the heap | sizing call + destination block in the caller's frame (9.1) |
| 20 | `prims/prims_actors_runtime_asm.silica:2867, 2880` | `_silica_rt_build_list_from_words` | same | same |
| 21 | `prims/prims_actors_runtime_asm.silica:2944` | `_silica_rt_cstr_to_string` | builds a string in the heap | destination block in the caller's frame (9.1) |
| 22 | `prims/prims_actors_child_table_asm.silica:1657, 1684` (`_silica_rt_supervisor_get_child_info_acb`), `1870, 1884, 1904` (`_silica_rt_supervisor_which_children_acb`) | supervisor query replies | records, chunk, handle in the heap | built in the replying supervisor's frame; delivered by the 5.3 reply copy (9.1) |
| 23 | `ESP32-S3_raw/terms/` (`term_aggregate_helpers:679`, `prims/prims_actors:313`, `prims_checked_int64:73`, `prims_list:449`; `term_message_copy`) | board twins | `silica_rt_region_alloc` is `.set` to `silica_rt_alloc` | OUT of phase 4 (hosted only); board takes this in phase 9 |

**Builtin `heap_used()` (not in the table above; found by review).** It returns the bytes handed out by
`_silica_rt_region_alloc` and not yet released. Lives in: `prims/prims_actors.silica:231, 237` (builtin name lists),
`:1110` (maps to `_silica_rt_heap_used`), `:1387` (`emit_runtime_nullary`); `prims/prims_actors_runtime_asm.silica:3874`
(`_silica_rt_heap_used`, an acquire load of the global counter `_silica_rt_heap_in_use`, declared `.comm` at `:4003`, updated
at `:3563, 3783, 3801, 3835, 3860` inside the arena allocator and `_silica_rt_actor_dealloc_region`). The `ESP32-S3_raw`,
`linux_aarch64` and `linux_x86_64` trees have it too (`prims_actors.silica`; the Linux runtime asm files). Phase 4 consequence:
with `_silica_rt_region_alloc` and its counter deleted, `heap_used()` has nothing to measure on the hosted targets; it must be
removed or redefined (for example as the mailbox-buffer plus call-record bytes, a Lee decision), and the 27 trials in
section 4 that read it go with that decision. The board keeps the allocator until phase 9, so the board builtin stays.

**ACB words used by the hosted heap (apple_silicon_mac, verified by grep of `#160/#168/#176/#184`).**

| ACB word | Meaning | Where |
| --- | --- | --- |
| #160 | newest arena block (header: prev, size) | `prims_actors_runtime_asm.silica:3518, 3538, 3570, 3823-3826` (init, dealloc walk, alloc) |
| #168 | bytes mapped so far | `:3519, 3571, 3829-3831` |
| #176 | bump pointer | `:3520, 3553, 3572, 3776-3782, 3834` |
| #184 | limit of the newest block | `:3521, 3555, 3573, 3799, 3828` |
| #160, #176 read only | arena position snapshot for owned records (exit reports): copied to the report-owner record and to node +40/+48 | `:4706-4708, 4751-4753` (`_silica_rt_owned_record_begin`), `prims_actors_child_table_asm.silica:2482-2484, 2507-2509` |
| global `_silica_rt_heap_in_use` | process-wide heap byte counter (not an ACB word) | see `heap_used()` above |

No other ACB word is used by the heap in the files grepped. #192 (supervisor actor_ref) is NOT a heap word; the design's
"#160..#184" range is exactly these four words (160, 168, 176, 184). Unverified: `prims_actors_carrier_asm.silica` reads
`[x19, #176]` and `[x19, #168]` at lines 646, 698, 2072, 2115; those registers may not hold an ACB, and whether they are the
heap words was not established, so check them when deleting #176.

Count: 22 hosted sites in the table (rows 1-22; row 23 is the board and not counted), of which 21 are planned (named in design 5 or 9.1).

**Unplanned (1):**

* U1. `prims/prims_memory.silica:746` (`emit_ev_region_alloc`, the allocator behind the evacuation routine `L_ev_heap`, which phase 2 introduced and whose comment says "only behaviours, sends and spawns evacuate into the heap"): it calls `_silica_rt_region_alloc`. Design 9.1 does not list it (it postdates the survey). Phase 4 must either delete the heap-evacuating `L_ev_heap` variant or retarget it to a frame/destination block, otherwise deleting the heap leaves a dangling `B _silica_rt_region_alloc`. The `linux_aarch64` twin has it too (`prims_memory.silica:743-748`).

Other observations (not heap uses, for the Opus owner):

* `bmv_state_reuse_asm` (`prims/prims_actors.silica:630`, `BL _silica_rt_region_alloc` at ~639) and `bmv_state_asm` (596) are PHASE 3 deletions (4.6). If phase 3 lands first they are already gone; if not, phase 4 cannot delete the heap.
* Already gone (phase 2): `term_message_regions.silica`, `aggregate_return_heap_promote_x0_copy` (not found in `term_aggregate_helpers.silica`). `canonical_arena_runtime_asm.silica` still exists; it is phase 5 (9.2) but `L_mc_is_canonical` (row 8) reads its table, so phase 4 deletes the reader first.
* `compiler/src/lexer/fix_case_done_tuple_rebox.py:19` mentions `_silica_rt_region_alloc` in a rewrite script (text only; check it is dead).
* Design line numbers in 9.1 are stale (for example `term_message_copy` 922-936 is now 1062-1081); the table above is current.

## 3. Open decisions phase 4 needs

Lee answered P1-P15 on 2026-10-24 (all confirmed); the items below are those that touch phase 4. "Default" is the design's recommendation.

| Item | Question | Default | Status |
| --- | --- | --- | --- |
| P11 / decision 39 | Spawn whose initial state exceeds the child's lowered reservation: who fails and with what reason? | the spawner fails with `(:explicit, :state_too_large)` (not the child; reason renamed from `:stack_exhausted`) | confirmed, no action |
| P12 | ACB growth to 592 B and call record to 176 B | grow both (no reuse of the unverified gaps #24..#71, #88..#127) | confirmed; the call record layout is built in phase 4 (5.3) |
| P5 | Per-slot copier tables at spawn, restart, fallback copy | per-slot tables; slots never share nodes | confirmed; phase 4 spawn/restart must use phase 3b's tables |
| P14 / Q19 | Unbound `rec` is E2010 everywhere (copier relies on every `ref?` naming its layout, KIND 0 never a reference) | enforced in phase 0 | confirmed; verify phase 0 landed before trusting KIND-0 assumptions |
| Q17 (decision 7) | Failed send to a dead actor frees the buffer with the node | yes | decided |
| Q14 (decision 11) | Row spec buffer per supervised child; copy on every start/restart | yes, cost proportional to spec size | decided |
| 13.6 | Reply into another actor's reservation: fault handler attributes faults to the current actor; futex-path park needs a published SP with margin `K` | replier pre-commits with `_silica_rt_stack_grow_to(caller_acb, dest)` after measuring; reply that does not fit sets `reply_set = 4` and the caller fails; constant `K` is already fixed by design 5.3: a per-target constant, 512 B on the hosted targets (the wait path's own frame depth plus margin; the runtime's wait routines are leaf-ish and well under it) | `K` = 512 B hosted needs no decision (Review corrections); the board value is not stated in 13.6 or 5.3. Design 13.6 says the caller fails when `reply_set = 4`; silent overwrite of a parked frame is the risk |
| 13.9 | Board keeps `silica_rt_state_release`/`silica_rt_heap_reaches` until phase 9, so board and hosted differ for the chunk | stated by 13.9 (Lee's ROADMAP board gap note records the lag) | needs Lee only if the board must match earlier |
| 13.12 | "A part that owns its own buffer" has no instance; only the whole message is forwarded (5.2) | implement whole-message forwarding only | design implements whole-message forwarding only (13.12 states the rule; 13 does not record a confirmation) |
| 13.8 | Runtime-owned memory outside the stack (mailbox buffers, call record, row spec buffer) is not "the heap" of decision 2 | read that way; each has one owner and one release path | the design's own reading (13.8); 13 does not record a confirmation, so note it in the hand-off |
| `call_with_timeout` (5.3) | Late reply after the caller left (`reply_set = 3`) | late replier drops it without copying | chunk 11 (not started); phase 4 should leave the state value 3 reserved, not implement it |
| Unplanned U1 | Fate of `L_ev_heap` (section 2) | delete the heap variant | **needs Lee** only if some target still needs heap evacuation |
| Pass criterion (phase 3 carry-over) | Memory gate is per-unit self-build maximum, or the synthetic parse batch | per-unit self-build (the stated benchmark) | **needs Lee**, open since `Phase3_stage2_analysis.md` section 5; phase 4 inherits it |

## 4. Phase 4 trials (design 11.3)

Checked with `find trials -maxdepth 4 -name '*<name>*'` on 2026-10-29: none of the phase-4 trials exists yet. Each trial is
a source plus `.scout`/`.sout`/goldens derived from real output (Lee's rule: the `.sout` must equal the `.scout`; see
`silica-trial-golden-derivation-traps`: byte offsets, atom-index exit codes, `external_danger` root body).

| Rule | Trial | Suite (exists) | Exists | Shows |
| --- | --- | --- | --- | --- |
| decision 30 | `list_copied_on_send_sender_pops` | `actors_addition` | no: to write (Sonnet) | sender casts a list and returns; receiver reads it intact; receiver `prepend` does not disturb the sender's list |
| decision 31 | `crashed_actor_queued_message_buffers_released` | `actors_addition` | no: to write (Sonnet) | 1,000 restarts with queued messages; process memory flat (needs a stable probe, RSS or footprint, to be chosen; measured, not asserted by the trial alone) |
| decision 32 | `forwarded_message_not_copied` | `actors_addition` | no: to write (Sonnet) | relay forwards 10^5 messages; allocator probe counts no copies (the probe itself must be defined; closest existing trial is `actor_behavior_forward_cast`, which covers behaviour only) |
| decision 33 | `reply_in_caller_stack_pops_with_frame` | `actors_addition` | no: to write (Sonnet) | reply lies below the parked SP and is gone after the frame pops |
| decision 33 | `reply_too_large_for_lowered_reservation` | `actors_addition` | no: to write (Sonnet) | caller fails with `(:explicit, :reservation_exceeded)` (was `:stack_exhausted`, decision 39) |
| decision 15 | `spawn_state_in_child_base` | `actors_addition` | no: to write (Sonnet) | spawner's frame pops before the child's first dispatch; child reads its state intact |
| decision 11 | `supervised_child_restarts_with_version` | `supervisors_addition` | no: to write (Sonnet) | 1,000 restarts, each start a copy, memory bounded |
| decision 22 | `send_then_use_*` catalogue (design 18.6) | `error_enforcement_addition` | no: to write (Sonnet) | E2301 after an explicit move; belongs to phase 6, listed because `move(x)` becomes a copy in phase 4 and its `\|mv` tag stays a checker-only marker |

Gate suites named by the phase 4 row, all existing directories: `actors_addition`, `supervisors_addition` (plus
`supervisors_board_defects_addition`, `supervisors_host_defects_addition`), `bees_regions_addition`, `ffi_addition`,
`region_hazards_open_addition` (and `region_hazards_open_errors_addition`; staged trials now pass or are promoted),
`cpu_discovery_and_spawn_pinning`, `scheduler_policy_addition`. `bees_regions_open_addition` also exists; whether it is in
the gate is Lee's call. Trials that pass a region down and `write_ref` a fresh node into a caller cell become errors in
phase 6 (the E2302 `write_ref` rule, design 6.3 and 11.1 row 6; 13.4 states the rule, not the phase); none is expected to change in phase 4.

**`heap_used()` trials (27, verified by grep of `trials/`).** 27 trial sources (`.silica`) call `heap_used()`:
`actors_addition` 12 (`behaviour_case_arm_call_reply_no_heap_growth`, `behaviour_list_message_reply_no_heap_growth`,
`behaviour_string_message_float_state_no_heap_growth`, `behaviour_string_message_reply_no_heap_growth`,
`heap_used_reports_bytes`, `record_message_casts_hold_state`, `tuple_message_casts_hold_state`, and the five
`zero_heap_growth_*`), `bees_regions_addition` 2 (`bees_sd7_message_region_released[_in_flight]`),
`bees_regions_open_addition` 1 (`region_in_returned_record_released`), `carriers_addition` 1
(`workers_two_field_record_return_at_arena_block_end`), `device_actor_addition` 1 (`device_led_row_constant_heap`), and
`stack_budget_board_addition` 10 (board). 721 `.ascomp` files (mostly `ordered_data_structures`) also contain the string, so
`grep -rl` on `trials/` gives 750 files; the 27 are the `.silica` sources. Phase 4 consequence: the hosted 17 assert on the
heap counter that phase 4 deletes (growth stays zero, or `heap_used` bytes are reported), so they must be rewritten against the
replacement measure or removed with the builtin, with goldens derived by Lee's rule; the 10 board trials are unaffected until
phase 9. `heap_used_reports_bytes` tests the builtin itself.

Note: trials whose goldens print message copies or atom indices will drift when the reply/spawn code changes; refresh only by
Lee's rule (`.sout` = `.scout`), never regenerated blindly (`silica-goldens-not-auto-regenerated`).

## 5. Gate and smoke test for phase 4

Copied from design 11.1:

* Gate: the compiler builds (incremental development build, `make INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in `compiler/src`, published compiler as builder) and the trials stay green on the targets the phase touches (`make integrate`, not bare `make`): `actors_addition`, `supervisors_*`, `bees_regions_addition`, `ffi_addition`, `region_hazards_open_addition`, `cpu_discovery_and_spawn_pinning`, `scheduler_policy_addition`. No gen1/gen2/fixpoint run (the single fixed point is phase 10).
* Smoke test: the compiler under the phase-4 compiler. The per-unit process loop is a spawn + call + reply per unit, which exercises 5.3 and 5.4 hundreds of times per build. Build the compiler's own units with the phase-4 compiler and run the result on `trials/base`.
* Design 11.2: phase 4 times `make integrate` before and after; a suite that doubles is examined (levers: forwarding elision and adoption).

Memory check implied (Lee's target: the compiler stays under 4 GB physical footprint with no swapping for more than 30 s;
benchmark is the self-build, memory first, then time). Measure physical footprint per unit with
`programmer_tools/ram_profile_unit.sh` (see section 1), swap/compression recorded.

Baseline A (RSS, NOT footprint): the tables below are from `Phase3_stage2_analysis.md` sections 1 and 2 (written 2026-10-28,
stage-2 compiler = the stage-2 source built by stage 1, versus the old 999939; wrapper RSS from the Haiku outputs
`meas_4a/4b/4c.out`; none is a self-build; no `data/*.tsv` profile or git commit is recorded for them):

| unit | old 999939 MB | stage 2 MB | stage 2 s |
| --- | --- | --- | --- |
| emitter_core | 3585 | 606 | 10.53 |
| wbt_map | 2731 | 1169 | 8.22 |
| tc_expressions_actor_spawn | 4389 | 1196 | 9.25 |
| tc_actor_supervision_messaging | 2197 | 729 | 4.78 |
| tc_binary_ops | 2379 | 708 | 5.08 |

| parser batch (k functions) | tokens | stage 2 s | stage 2 MB | exit |
| --- | --- | --- | --- | --- |
| 1250 | 22.5k | 0.89 | 356 | 0 |
| 2500 | 45k | 3.04 | 1310 | 0 |
| 5000 | 90k | 11.33 | 5042 | 0 |
| 10000 | 180k | 45.35 | 5444 | 70 (stack fault, 19 GB reservation used up) |

Baseline B (footprint, self-build, per-unit, from `benchmarking/memory_use_reports/data/`; peak of any unit, 354-355 units
unless noted): `20261028T1927Z_silica-compiler-4a63c6254fb6.tsv` (git_head 0adcec2d8c, stage-2-era compiler, 1740.8 MB,
`type_checker_core`); `20261029T155308Z_silica-compiler.tsv` (0adcec2d8c, 670.9 MB, `type_interner`);
`20261029T232435Z_silica-compiler.tsv` (bef95ca174, 669.4 MB); `20261030T202324Z_silica-3c.tsv` (bef95ca174, stage 3c,
1740.8 MB); `20261031T004658Z_silica-3d-hand.tsv` and `20261031T031743Z_silica-3d-gen1.tsv` (bef95ca174, stage 3d, 4812.8 MB,
`type_interner`: above the 4 GB target). In the 3d-gen1 file `wbt_map` is 2662.4 MB and `emitter_core` 2252.8 MB. The
`seed-compiler` files are single-unit probes (up to 3481.6 MB on `emitter_core`). Pick the phase-3 closing profile
(`20261031T031743Z_silica-3d-gen1.tsv`, the compiler published as 999937 was built by stage 3d; git_head bef95ca174 is the
last commit, the working tree was dirty) as the phase 4 "before", and re-measure rather than reuse a figure with a different
`git_head`.

Pass condition for phase 4: no unit above its stage-2 figure by more than noise (investigate any regression), every unit
under 4 GB footprint (Baseline B shows the stage 3d profile already above it on `type_interner`; record, do not blame phase 4), no swap over 30 s, and the parser-batch numbers no worse; deleting the heap must not move bytes onto
the stack of the pipeline/unit actor (message buffers and replies are the new consumers). If the phase 3 gate is still
failing the 4 GB batch target when phase 4 starts, record both and do not attribute the failure to phase 4. Phase 4 should
reduce footprint only where messages/replies were retained in the heap (the pipeline actor's reply per unit); expect no help to the
quadratic parse term, which is not a phase-4 item.

## 6. Order of work once phase 3 closes

Roles follow `.claude/skills/silica_building/SKILL.md`: Haiku controls all builds and script runs; Fable (Opus if Fable is
unavailable, with Lee told) modifies the compiler; Sonnet evaluates compilation and trial results and writes trials and scripts.

1. Re-grep section 2 on the closed phase-3 tree (lines move; phase 3 deletes `bmv_state_*`) and record the delta in a hand-off note. (Sonnet evaluates the grep output; Haiku runs any script.)
2. Fable (or Opus): compiler changes on the Mac first, in this order; the compiler-code model does not build:
   a. measuring mode finished and KIND 7/8 entries; destination cursor in `L_mc_root` (rows 8, 9);
   b. mailbox buffer, `+8/+40` words, dead-send and end-of-actor frees, `_silica_rt_actor_*` (rows 4, 5, 12, 13);
   c. reply into the caller's stack with the 176 B call record, `reply_set` states, pre-commit and the `K` = 512 B margin (rows 6, 7);
   d. spawn and restart into the child's base, row spec buffer (rows 1-3, 14, 15);
   e. `|_mvs` reinterpretation, `|_mvr` and the move helpers removed (rows 10, 11);
   f. runtime list/string builders to destination blocks (rows 18-22);
   g. `heap_used()` removal or redefinition (section 2) and the heap deletion: U1, rows 16, 17, ACB #160..#184 (only after every other caller is gone; grep must show zero `_silica_rt_region_alloc` calls).
3. Fable (or Opus): port the same diff to `linux_aarch64`, then `linux_x86_64` (twins; use the x86 `x86_isa`/`x86_mem` helpers), before phase 5 starts on the Mac. A `diff` of the changed functions across the three trees goes in the hand-off.
4. Haiku: builds (build-slot lock, one build at a time, never while Lee's build runs), `make integrate` on the gate suites, the per-unit footprint profiling of section 5, the smoke test run. Haiku reports raw results; it does not regenerate goldens.
5. Sonnet: evaluates every build and trial result (successes and failures, including `.sams`/golden diffs), and writes the section 4 trials and any scripts (derived goldens by Lee's rule).
6. Lee decides: section 3 items marked "needs Lee", the pass criterion, and publishing the phase-4 compiler as the builder for phase 5.

## Review corrections

Each point was checked against the repo on 2026-10-31.

1. `heap_used()` was missing: added to section 2 (locations, phase 4 consequence) and its 27 `.silica` trials to section 4. Verified: 750 files under `trials/` contain the string, of which 27 are `.silica` sources and 721 `.ascomp`.
2. ACB heap words: verified as #160, #168, #176, #184 plus the global `_silica_rt_heap_in_use`; read-only uses of #160/#176 added; carrier-file reads of #168/#176 could NOT be attributed and are marked unverified.
3. `K`: this document said it was still to be chosen and needed Lee. Design 5.3 fixes it as a per-target constant, 512 B on the hosted targets; 13.6 only names it. Board value not stated.
4. RSS versus footprint: convention stated once in section 1; the stage-2 table is explicitly RSS.
5. Baselines: the stage-2 tables have no commit or `data/*.tsv`; the source file and date are stated. Footprint profiles with their `git_head` listed as Baseline B.
6. Roles: section 6 rewritten to the three roles in `silica_building/SKILL.md`; "spec/doc text" removed from Sonnet because the rule does not give docs to any role.
7. Section 13 claims: removed "confirmed" for 13.8 and 13.12 (13 records the design's reading, not a Lee confirmation); "accepted" for 13.9 reworded; "needs Lee: K" for 13.6 corrected; the phase 6 timing attributed to 13.4 now cites design 11.1 row 6. 13.6 (pre-commit, `reply_set = 4`, caller fails) and 13.9 and 13.12 content were supported.
