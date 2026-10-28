# region_hazards_open_addition (INTEGRATE_PENDING)

Failing-before trials for the chunk 4 region-safety hazards that stage 0 fixes (H1, H3, H4, H5)
and for the stage 8 bounds outcome (Q9), from
[`region_memory_safety_design.md`](../../compiler/design_documents/region_memory_safety_design.md)
§1.3, §8, §9.4, §13, §14.2 and §15 Q9. Each `.scout` states the correct behaviour, so the trials
fail with today's compilers. The `INTEGRATE_PENDING` file keeps this directory out of tree-wide runs
on the host and on the board (both report it as `SKIPPED (INTEGRATE_PENDING)`), so the gate stays
green while the defects are open. Run them by hand:

```
make -C region_hazards_open_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler   # from trials/
make integrate TRIAL_TARGET=host TRIAL_SUITES=region_hazards_open_addition                                                     # through the tree runner
```

The harness ignores `SILICA_COMPILER` from the environment; pass it on the make command line.

The two compile-error trials (E2313, E2314) are in the sibling suite
[`../region_hazards_open_errors_addition`](../region_hazards_open_errors_addition), which is also
`INTEGRATE_PENDING`. They cannot be here: this suite compiles every unit in one batch, and a unit the
compiler rejects (as it will once E2313 and E2314 exist) aborts the batch for every trial (memory note
"compile-defect trials need their own directory").

## Trials

"Today" is the published Mac compiler `binaries/silica-compiler` (999942), 2026-10-22, from
`make -C region_hazards_open_addition integrate` and from runs of the built binaries.

| trial | hazard / item | design | today (999942, Mac) | what fixes it | stage |
|---|---|---|---|---|---|
| `four_actors_same_family_inserts` | H1: canonical arena bump and grow are unlocked | §1.3 H1, §9.4, §14.2 `two_actors_same_family_inserts` | **fails 20 of 20 runs**: 18 end with a builder failure report (reason_tag 4) and status 70, one was killed (137), one hung until the 120 s alarm (142) | atomic bump for arena allocation and a CAS insert in `_silica_rt_canonical_arena_lookup` (§9.4); the arena grow path needs the same care | 0 |
| `wbt_map_tuple_value_escapes_via_let` | H3: let-bound frame aggregate passed by name is not promoted | §1.3 H3, §14.2 | **fails every run**: prints `1 <address-like number>` for key 1's value, then ends with SIGTRAP (status 133, "Trace/BPT trap: 5") reading the string | promote a let-bound frame aggregate passed by name, not only a literal `tuple_make`/`record_make` (`is_aggregate_make`) | 0 |
| `reply_after_callee_ended` | H4: a composite reply lives in the replier's arena, freed when it ends | §1.3 H4, §13 (targeted stage 0 fix for H4), §14.2 | **fails every run (5 of 5), silently**: the kept reply `{7, 14, 21}` reads `70, 140, 210`, the second replier's data in the remapped arena; exit 0 | a reply (and state) the caller keeps must not live only in the replier's arena (copy into the caller, or keep the block until the caller is done) | 0 |
| `region_alloc_failure_ends_actor` | H5 (closest deterministic neighbour; see below) | §1.3 H5, §10 | fails: `105`, then `[silica] abort: region allocation failed at <PTR>`, status 71 | **needs Lee's decision**: the `.scout` asks for the actor to end and be restarted; §10 says region growth failure and H5's null paths stay abort 71 | 0 (H5) / Q9 |
| `buf_bounds_ends_actor` | Q9: out-of-bounds index in an actor | §8, §14.2 `buf_bounds_ends_actor`, §15 Q9 (a) | fails: `105`, then `[silica] abort: buffer index out of bounds at <PTR>`, status 71 | `L_buf_bounds` in an actor ends the actor with `(:explicit, :buf_bounds)`; abort 71 only in `main` | 8 |
| `buf_invalid_size_ends_actor` | Q9: invalid buffer size (`L_buf_invalid`) in an actor | §8 ("same for `L_buf_invalid`"), §10, §15 Q9 | fails: `105`, then `[silica] abort: invalid buffer size at <PTR>`, status 71 | `L_buf_invalid` in an actor ends the actor with `(:explicit, :buf_invalid)` | 8 |
| `list_index_ends_actor` | Q9: list index past the end in an actor | §15 Q9 ("the list-index abort by the same reasoning") | fails: `109`, then `[silica] abort: list index out of range at <PTR>`, status 71 | `L_lat_oob` in an actor ends the actor (reason atom not fixed by the design) | 8 |
| `buf_bounds_in_main_still_aborts` | Q9 guard: in `main` it stays abort 71 | §8, §15 Q9 (a) | **passes** (it must keep passing after the Q9 fix) | nothing; it catches a fix that routes `main`'s bounds failure through actor failure | 8 |
| `write_ref_young_into_older_cell` | Phase 2 open hazard: `write_ref` of a pointer to a younger frame's node into a ref cell of an older frame; the evacuator scans old aggregates but not old REF1/REFTUP cells | Phase2_notes.md §3 item 4 | **fails** (phase 2 Mac compiler, 2026-10-26): prints `6102673616` (a stale value read through the dangling pointer) then `0`; wanted `7` then `0` | scan old ref cells in the evacuator, or promote the stored pointer in `write_ref` | chunk 15 phase 2 |
| `write_ref_young_into_heap_shell_ref` | the same through a ref inside an actor's heap state shell; compiles (picked up by the `find`-generated `silica.config`) | Phase2_notes.md §3 item 4 | **fails** (phase 2 Mac compiler, 2026-10-26): prints `0`, `0`, `0`; wanted `0`, `7`, `0` | same | chunk 15 phase 2 |

In the other suite:

| trial | item | today | stage |
|---|---|---|---|
| `e2313_alloc_buf_literal_size_mismatch` | E2313: `alloc_buf(r, 10)` bound to `buf(L1, normal, int64, 16)` | accepted: compiles, runs, prints 5, exit 0 | 8 |
| `e2314_read_buf_literal_index_out_of_range` | E2314: `read_buf(b, 15)` with N = 10 | accepted: compiles; the run ends with `[silica] abort: buffer index out of bounds`, status 71 | 8 |

Their `.golden_fail` files are **provisional**: E2313 and E2314 do not exist in the compiler yet, so
the goldens could not be re-derived from real output (the rule for error goldens). They follow the
existing golden format exactly (the compiler's progress lines up to `Type checking...`, then the error
block, `TypeError`, the metadata block), with: the position of the offending literal (the `10` and the
`15`); a message written from §8/§10 (`buffer length mismatch: ...`, `buffer index out of range: ...`);
and `spec:sect12.3.3`. When the codes are implemented, re-derive both goldens from real output with
the same code and construct, then move the two trials to `../error_enforcement_addition` (§14.1 puts
them there) and delete that suite. The negative-literal-index case of §14.1 is not written yet.

## Expected outputs and how they are compared

The actor trials have a `<trial>.scout.multiset` marker holding `unordered`, which selects
`../compare_scout_unordered.sh`: failure reports, the root-exit note and `[silica] abort:` lines are
folded (`<PTR>`), lines compare as a multiset, and the exit status (the last line) compares exactly.
The reporters print one line a report (`failure report: worker reason_tag 4`), not the banner, so the
goldens do not depend on banner fields. `four_actors_same_family_inserts` and
`wbt_map_tuple_value_escapes_via_let` print in a fixed order and compare with `diff -Bw`.

The Q9 trials use the `identity_restart` pattern (supervisors_addition): main never calls an actor
that ends mid-call; a crasher actor calls the worker with the bad value, so the crasher also fails
(its call raises `actor_not_found`, reason_tag 4); the reporter counts the two reports down and ends
main's `wait_for_exit` with `cast_exit(0)`; main then calls the restarted worker. The worker counts
calls in its state, so the second answer (105 again) shows a restart from the initial state; an actor
that survived the bad access instead would answer 106. The mechanics were checked today with a
control that replaces the bounds fault by a divide by zero, which already ends only the actor: it
prints exactly the `.scout` lines except `failure report: worker other reason` (a fault is not
reason_tag 4), 5 of 5 runs. The banner does not print the reason atom, so `:buf_bounds` /
`:buf_invalid` themselves are not checked; only reason_tag 4 (explicit) and the behaviour name are.

## Notes per trial

**H1 is not deterministic by construction.** The collision needs two carriers to load the arena's
bump pointer (or start a grow) within a few instructions of each other. On the Mac today it fails
every run because four builders run 20,000 inserts each at once (20 of 20 runs failed; one run takes
about 12 s). Controls, same binary shape: one builder alone passes; one actor building the four maps
one after another passes 3 of 3; four builders all spawned with core 0 still fail 3 of 3, so on the
hosted runtime the core argument does not serialise them (actors are balanced across carrier threads,
memory note "core pinning: hosted vs raw"), and the race needs no explicit cores. A pass after the fix
is evidence only over many runs. On a host with fewer cores, or under load, a run can pass by luck.
The builder's failure is reason_tag 4 (explicit); the banner does not say which explicit reason.

**H3** reuses the staged repro of memory note `silica-aggregate-var-arg-not-promoted` (2026-09-08).
That file lived in a session scratchpad and is lost; only a trial-cache `.ascomp` of it is left in
`ordered_data_structures/wbt_core/.trial_cache/wbt_map_tuple_value_escapes_via_let/`. It is rebuilt
here from the fixed and gated literal companion `ordered_data_structures/wbt_core/wbt_map_tuple_value_escapes_frame`,
changed only where the hazard needs (the value is a let-bound name), plus a `scrub` call that reuses
the stack. Control, same program with the literal at the call: prints `1 10 v`, `2 20 v`, exit 0.

**H4** is deterministic on the Mac (5 of 5, always the second replier's values, never a fault): the
first replier's arena is unmapped when it ends and the second replier's arena is mapped at the same
address. Control, same program with the first replier kept alive: prints 7, 14, 21, exit 0. On
another host the address may not be reused, and the failure is then a fault (status 70) instead.

**H5 cannot be provoked deterministically from a trial.** Its two unchecked paths:

- the actor arena (`_silica_rt_region_alloc`, `LBBra_grow_failed` returns 0) maps max(64 MB, request)
  per block, and no allocation whose size a program controls goes to the actor arena: records,
  tuples, message copies and list chunks all have sizes the compiler fixes;
- `emit_alloc_region`'s `malloc(4128)` fails only once the address space is exhausted. A C probe
  (2026-10-22) that malloc'd every large block it could still found 290 free 64 MB holes and a
  working `malloc(4128)` afterwards, and on macOS `setrlimit(RLIMIT_AS)` / `RLIMIT_DATA` to 1 GB
  fails with EINVAL (`ulimit -v` too), so no cap can force it; the harness sets none anyway.

So `region_alloc_failure_ends_actor` drives the **checked** neighbour: a 2^56-element `int64` buffer
(2^59 bytes, no multiply overflow) in a worker makes `L_region_grow`'s `_silica_rt_raw_alloc` return 0,
which branches to `L_region_overflow` (abort 71). Its `.scout` records the outcome requested when the
trial was written (the worker ends, is restarted, main continues). That conflicts with §10 ("region
growth failure (abort 71), H5's null paths (abort 71)"): a stage-0 fix that follows the design keeps
this trial failing. If Lee keeps §10, its `.scout` becomes `105`, `[silica] abort: region allocation
failed at <PTR>`, `71` and the trial passes today, as a guard that the check stays. The `.scout` is
not changed without Lee.

## Suite layout

The Makefile, `compare_scout_multiset.sh` and `run_integration_exit_after_marker.py` are copies of
`../bees_regions_open_addition`'s. One change: the `silica.config` rule also takes symlinked units
(and skips `.trial_stdlib/`), because the trials use two stdlib modules through symlinks here:
`wbt_map.silica` (`../../compiler/stdlib/data_structures/wbt_map.silica`) and `Supervisor.silica`
(`../../compiler/stdlib/Supervisor.silica`). They are compiled and linked with the suite, so the run
also reports `wbt_map has no .ascomp file` and `Supervisor has no .ascomp file`. The symlinks lead
into `compiler/`: a bulk edit under `trials/` reaches the stdlib through them.

No trial has an `.ascomp`: today's assembly is the defective codegen. When a fix is in a built
compiler and its trial passes on every host, record the `.ascomp` goldens (Mac, then `linux_aarch64`
on pix and `linux_x86_64` on nix) and move the trial with its `.scout` (and marker files) to a gated
suite (`memory_region_addition` for the bounds outcome, a region-safety suite for the hazards; the
wbt_map trials need a suite that compiles `wbt_map`, such as `ordered_data_structures/wbt_core`).
Not run yet on pix, nix or the board.
