# Chunk 15 phase 3: compiler memory, a theoretical account (2026-10-28)

Theory only, by reading; no build, run or measurement was made or requested. Awaiting Lee's review before any measurement.
Sources: `Phase3_notes.md` §§6-8, `chunk15_stack_memory_design.md` §§1, 2.1-2.5, 3.3-3.5, 4.4, `prims_actors_stack_asm.silica`,
`main.silica`, `compiler/src/Makefile`.

## 0. Facts the theory must explain

* The Makefile build is process-per-unit and serial (`main.silica` header: exit 75 "between units of a process-per-unit batch, the Makefile's
  reclaim loop"; Makefile 297-378). A build's peak is therefore the maximum over units, never a sum. One pipeline actor does a whole unit in
  one dispatch.
* Per-unit peak RSS (2026-10-28): stage 1 is 7-14x LOWER than 999939 (emitter_core 256 MB vs 3,585 MB) and 10-20x SLOWER.
* Lee: the compiler as a whole is much too big and must return to about its pre-stack size to run on a Pi 5.
* These agree only if the "too big" compiler is not stage 1 on those five units. The theory must say what else is big (sections 3, 4).

## 1. Accounting model

Let one unit compile in one process. Resident memory at time t is the pages touched and not returned.

### 1.1 Before the stack model (heap with region release heuristics)

`RSS_old = binary + tables + sum of ALL allocation of the unit` (heap bump pointer, 64 MB mmap blocks, freed only at actor end; strings in a process-wide
bump arena never freed; messages and replies copied into the sender's or caller's arena, never freed). The release heuristics (mark/release, region
release) were disabled as unsound, so in effect nothing is freed during a unit. Garbage counts in full. Terms: live data L (ASTs, type tables, world
env, SIR) plus garbage G (every temporary list, every rebuilt environment, every intermediate string) plus per-actor arena slack (up to one 64 MB block per
actor) plus machine-stack depth of the recursion. Grows with input size n as the total allocation count A(n), which is far larger than L(n). That is why
999939 needs 2-4 GB on a unit.

### 1.2 Now (frames, adoption, evacuation, state area, reservations)

`RSS_new = binary + tables + H_stack + H_interim + A_residual`, where

* `H_stack` = high-water of the committed run of the pipeline actor's stack. The committed run only grows during a dispatch (`grow_to` commits 1 MB chunks
  by `mprotect`; release happens only at the message boundary, §2.4). So resident = the DEEPEST point ever reached, not the live size.
  `H_stack = max over time of [ sum of live frames (fixed part + dynamic part) + adopted garbage + scratch ]`.
* Frame terms. A frame is the fixed part (registers, X29 region slots; the notes record regions as about 3x the SP-slab cost) plus a dynamic part holding the
  nodes the function allocated. Dynamic parts of adopted callees (return position) stay below the caller until the outermost consumer evacuates
  (option-1 rule, §3.3-3.4). Evacuation (§3.5) is two pass: copy to scratch below SP, then copy to the destination; transient cost = size of the evacuated value.
* `H_interim` = what phase 2 still puts in the old heap: behaviour result and state shell evacuated to the actor heap each dispatch (`bmv_state_asm`, `L_ev_heap`),
  messages and replies copied into arenas. Never freed until the actor ends. Phase 3 (state area, stages 3b/3c) is not built; until then this term is the old model's, unchanged.
* The state area (phase 3 onward): nodes of the live state, exact-size free lists, nodes never move (decision 21), holes reusable only by the same size, never decommitted
  while the actor lives under `:keep_state_area`. The fallback (§4.4) copies the whole state through scratch: transient 2x the state size.
* Reservation: virtual only. Each actor reserves hw.memsize + swap (`PROT_NONE`, NORESERVE), nothing committed at spawn. RSS is zero for it; only the committed run counts.
  Minimum committed per actor is the first fault (a page, doubling to 1 MB chunks), plus a 64 KB signal alt stack for a thread-owned actor, plus the 1,040 B state header.
* Never-returned committed pages: because the pipeline actor takes the whole unit in one dispatch, `stack_policy` (`:keep_last_message`) and every release algorithm act
  only after the unit ends, when the process is about to exit. Within the unit there is no trimming.

## 2. What grows with what

| Term | input size n | recursion depth d | live actors k |
| --- | --- | --- | --- |
| live data L (AST, tables, SIR) | linear | no | no |
| old-model garbage G | linear to super-linear (total allocation) | no | no |
| fixed frames | no | linear, times frame size | one stack each |
| dynamic parts of non-adopted frames | no | bounded by the live set | one stack each |
| adopted garbage (callee dynamic parts kept until consumer) | grows with allocation made BY adopted callees along the chain | linear in chain length times garbage per level | per stack |
| evacuation scratch (transient) | size of the evacuated value (a whole list or state: linear) | at the evacuating level only | per stack |
| committed-never-returned slack | the gap between the high-water and the live size at the end | set by the deepest point | per stack, 1 MB granularity |
| reservations | no | no | virtual only, k times (RAM+swap) |
| state area holes | with number of dispatches and distinct node sizes | no | per actor |
| interim heap (phase 2) | with dispatches times state/message size | no | per actor |
| emitted code, atom and shape tables | linear in program (KB to MB) | no | no |

## 3. Candidate mechanisms that make the current compiler larger than before, ranked by expected contribution (reasoning only)

1. **Adoption garbage (stage 2 and any build whose own code uses the Step B rule).** The option-1 rule keeps a callee's whole dynamic part until the outermost
   consumer. A function that builds large temporaries and returns a small result through an adopting call keeps all of them; along a recursive chain they accumulate for the whole
   chain. In the limit adoption retains every allocation of the adopting chain, which is the old heap's "never free" for exactly those chains. Step B widened adoption
   (arguments of return-position calls, projections of let-bound names) precisely on the compiler's own hot builders. Stage 1 was generated by 999939, which lacks Step B, so
   the per-unit stage-1 numbers (the fact in section 0) could not show it. This is the only mechanism that makes the stack compiler's footprint approach the old one's and it grows with depth and with allocation per level. Largest expected contribution for stage 2. It is a theory about code not yet measured.
2. **High-water without return (committed run only grows within the dispatch).** RSS equals the deepest point, not the live set. One transient spike (a deep non-tail recursion over
   tokens, an evacuation of the whole declaration list, a type-table rebuild) is resident for the rest of the unit; the old heap had the same monotonicity but with total allocation as the
   bound, so this is a smaller, but unbounded-by-policy, term. Because the whole unit is one dispatch, no release algorithm can act.
3. **Evacuation scratch and the two-pass copy.** The transient equals the evacuated value. At a return the scratch sits below SP (adds to the depth at that point); at a dispatch end
   (phase 3) it starts at the bottom of the committed run, so every large evacuation commits fresh pages beyond the high-water that are then never returned. The quadratic-evacuation
   sites (Phase3_notes §7) are quadratic in TIME, linear in space, so they explain slowness, not size.
4. **Fixed-frame size times depth.** Frames hold node-indexed X29 region slots (about 3x SP slabs per the frame-region note). Deep non-tail recursion over token or declaration lists with
   d in the tens of thousands costs d times the frame size, committed forever. The old model also had frames but not the region slots on the same scale.
5. **Interim heap (phase 2) and later the state area.** Same cost as the old model for state/message/reply copies per dispatch; not a regression, but a floor under any reduction
   until stages 3b/3c remove it. Phase 3's holes and the 2x fallback scratch add to it. The count of dispatches per unit in the pipeline is not known to me.
6. **Reservations.** Virtual only. Cannot raise RSS. Matters for VSZ displays and for overcommit refusal on Linux (the code retries down to half of the default). Scales with k, the actor count (the compiler has three).
7. **Emitted code and tables.** KB to MB. Negligible.

Why per-unit stage-1 can be LOWER and yet the compiler "too big": stage 1 removes the old heap term G for its own data (high-water of depth replaces total allocation), which dominates on the units
measured. Mechanism 1 and the full-process footprint (including VSZ displays from mechanism 6) are the ones those units do not exercise.

## 4. What a Pi-5-sized compiler must keep, and what would have to change

Target: peak close to the live set plus a bounded multiple, `RSS <= binary + tables + c * L_max`, with c near 2 (live plus one evacuation transient), and time near the old compiler (no swapping).
Required properties from the theory:

* garbage must not be retained proportional to total allocation: adoption retention per chain bounded by a constant multiple of the live result;
* the stack high-water must come back down within a unit, not only at process exit;
* the evacuation transient must be bounded by the value and must not enlarge the committed run;
* depth cost must be proportional to the live frame state, not to dead dynamic parts.

Mechanisms that would have to change, each compatible with stack allocation (the means) and each a design choice for Lee, not decided here:

* **Adoption garbage limit.** Adopt only when the callee's dynamic part is expected to be mostly result (type/shape or a measured ratio), and evacuate at a bounded depth or size
  (a compaction every k levels, or when the adopted dynamic part exceeds a threshold). Restores freeing of callee garbage; trades a bounded copy for a bounded retention.
* **Popping and returning pages inside a dispatch.** After an evacuation at the outermost consumer, decommit (MAP_FIXED remap, already the only Darwin call that works) the committed
  run below SP plus a margin when `committed - (top - SP)` exceeds a threshold. Cheap per event; turns RSS from the deepest point into a decaying high-water.
* **Scratch placement and size.** Keep the scratch strictly below SP (as for returns) instead of the bottom of the committed run at dispatch end, and size it to the value; or
  evacuate in place by sliding when the source is dead, avoiding the two-pass doubling.
* **Boundary structure.** Split a unit across dispatches, or phases across actors (lexing, parsing, checking, SIR, emit) with `:release_on_return`, so the release algorithm and the state
  evacuation return pages between phases. One dispatch per unit forfeits every release policy.
* **Reservation policy.** Lower the default reserve for compiler actors (explicit `stack_policy(reserve, ...)`) so VSZ and overcommit behave on a Pi; this changes no RSS and is the least important for size.
* **Stage-2 source rewrites** (Step A style) of the specific builders are a stopgap for time, not a size mechanism.

## 5. Open questions for Lee

1. Which figure is "too big": resident, virtual, a Pi 5 run, or Activity Monitor on which build?
2. Is the benchmark the Makefile self-build (process per unit), whose peak is the largest unit?
3. Do you accept that the committed run is returned only by an explicit mid-dispatch trim, or should phases become dispatches?
4. Should adoption be allowed to retain unbounded garbage (option-1 as designed) or be limited by a rule?
5. After your review, which single measurement should come first (a minimal, targeted one, if any)?

## 6. Lee's answers (2026-10-28) and the target

* The figure is Activity Monitor's Memory column, which is the physical footprint (resident plus compressed plus swapped-out dirty pages), not RSS. Compressed and swapped pages count, so a slow run that swaps can show more than `time -l` "maximum resident set size". Reservations (PROT_NONE, never touched) are not in it.
* Target: the compiler generally stays under 4 GB with no swapping for more than 30 seconds.
* Benchmark: the self-build, one process per unit, memory first, then time.

## 7. Direction: split the compiler into more granular actors

Direction list note (2026-10-28): the first item of the direction list is the copy-or-keep rule at a return (keep the callee frame while its garbage is small relative to the result, copy the live result out once it is large; committed stack pages returned after an evacuation). It is decided as direction, not implemented and not measured; see the amendments under sections 3.3 and 3.4 of chunk15_stack_memory_design.md. The actor split below follows it.

Today one pipeline actor holds the whole unit (lex, parse, check, SIR, emit) in one stack for one dispatch. The progress lines already name the phases, and `parse_in_actor.silica` exists but is not wired in.

**Why it can help (theory).** An actor's stack is unmapped when the actor ends (`_silica_rt_actor_stack_free`), which is the only mechanism that truly returns committed pages mid-unit without a runtime change. A phase actor that finishes and exits returns its entire high-water, its adopted garbage and its scratch. So peak becomes `max over phases (phase working set + input copy + output copy)` instead of the deepest point over the whole unit. Mechanism 1 (adopted garbage) and 2 (high-water never returned) of section 3 are then bounded per phase. Release algorithms also get dispatch boundaries to act on, with phases as messages to a long-lived actor.

**Trade-offs.**
* Message copies. A message payload is deep-copied by the type-directed copier (phase 2: into the sender's arena, never freed; phase 3 design: into the receiver's mailbox buffer/stack; forwarding-only elision `|_mvs`/`|_mvr` avoids a copy when the sender never reads it again). Passing the token list, AST or SIR between phases copies the live data once per boundary, and during the copy sender and receiver both hold it (transient 2x the live value). If the sender's copy lives in a never-freed arena (phase 2) the copy is permanently added, which can cancel the gain. So the split only pays when the boundary value is much smaller than the phase's garbage, and when the sender exits (or the copy is elided) so its copy dies.
* Reserves and commit minimums. Each actor reserves RAM+swap virtually (no footprint) but its first fault commits at least a page, doubling to 1 MB chunks, plus 64 KB alt stack for a thread-owned actor. For about ten phase actors this is a few MB; negligible. On Linux/Pi the whole-machine reserve per actor may be refused by overcommit (the code retries down to half); set an explicit `stack_policy(reserve, ...)` per phase.
* Per-unit process model. It already caps the build's peak at the largest unit and discards everything between units. It does not reduce the largest unit's own peak, so it is why splitting inside a unit matters: the largest unit is the number to push down.
* Cross-phase state. The type tables, world env and interfaces are read by several phases. Copying them to each phase actor multiplies L; passing them by reference is not possible across actors (no shared heap). Keep them in a long-lived table actor and send queries (cast/call), accepting message cost, or re-derive them per phase from the iface files.
* Time. Copies and extra scheduling cost time; stage 1 is already 10-20x slower, so time is the second priority but must be tracked.
* Dispatch-end evacuation (phase 3) copies a long-lived actor's whole state through scratch; many small dispatches are cheap only if state stays small.

**What would be measured (after review):** per-phase footprint over time inside the largest units (which phase is the peak), the size of each boundary value (tokens, AST, checked AST, SIR) against the phase's own peak, and whether the sender's copy is released at actor exit. These decide whether a split lowers the maximum.

## 8. Haiku request list: first measurement (run only when the build-slot lock is free)

Goal: peak physical footprint over time for the self-build, one process per unit, with the published 999939 and with stage 1. Footprint, not just resident. No change to compiler source. Run the builds one at a time, 999939 first, in clean copies of the compiler tree so every unit recompiles.

Lock: `/private/tmp/claude-501/-Volumes-2T-silica/e3b4f0ea-081d-496d-bfaa-fe5a90e42862/scratchpad/build_slot/lock` (wait for the stage-2 build to finish and take the lock the usual way).

1. Write a sampling wrapper `$SCR/footprint_wrap.sh` (SCR = the scratchpad). It runs the real compiler in the background, samples the footprint of its pid every 1 s until it exits, records the exit code, and exits with it (75 and 76 must pass through):
```
#!/bin/bash
# env: REAL (compiler binary), LOG (output prefix)
"$REAL" "$@" & pid=$!
t0=$(date +%s)
while kill -0 $pid 2>/dev/null; do
  fp=$(footprint -p $pid 2>/dev/null | grep -i 'Footprint:' | head -1)
  echo "$(( $(date +%s)-t0 )) $pid $fp" >> "$LOG.samples"
  sleep 1
done
wait $pid; ec=$?
echo "END pid=$pid ec=$ec unit=$(cat silica.compile.inprogress 2>/dev/null)" >> "$LOG.samples"
exit $ec
```
   If `footprint` rejects `-p`, use `vmmap -summary $pid | grep -i 'Physical footprint'`. Check on a tiny unit that a line appears before the build.
   In addition run the real binary under `/usr/bin/time -l` is NOT needed for the first pass (it reports resident); if cheap, also record `peak memory footprint` from `/usr/bin/time -l` for the whole make run only.
2. For each of REAL = `/Volumes/2T/silica/binaries/silica-999939-macos-applesilicon` and then stage 1 (state its path):
   `cd <clean copy>/compiler/src && make clean && REAL=<path> LOG=$SCR/fp_<name> make assembly SILICA_COMPILER=$SCR/footprint_wrap.sh`
   (If `check-seed` objects to a script, install the wrapper under the compiler's expected name in the copy's `binaries/` and say so.) Record the total wall time.
3. From each `fp_<name>.samples` report: the maximum footprint over the whole build and which unit (the `unit=` field of the nearest END line or the progress phase), the top 10 units by peak footprint, the time each of the top 5 spent above 4 GB, any period longer than 30 s above the physical RAM minus 2 GB (swapping), and a footprint-versus-time series for the single largest unit (one value per second). Also `sysctl hw.memsize vm.swapusage` and swap used before and after.
4. Keep the machine otherwise idle (no other builds, browsers closed) so the footprint is the compiler's.
5. Do not run stage 2 in this pass; do not edit any file under compiler/src.

Report back: the three tables of step 3 for 999939 and stage 1, side by side, and anything that could not be sampled.
2026-11-01: superseded: alloc_region is a frame area (Lee's decision); see chunk15 section 3.8.
