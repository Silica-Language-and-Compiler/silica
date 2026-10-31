# Chunk 15 phase 3: stage-2 compiler measurements, analysis (2026-10-28)

Working file, not committed. Analysis only: no build, run or edit was made for this note.
Sources: `Phase3_memory_analysis.md` (theory, target), `Phase3_notes.md` sections 6-8 (old numbers), `chunk15_stack_memory_design.md` 3.3 and 3.4 (amendment 2026-10-28),
memory note `feedback-compiler-memory-pi5`, and the Haiku outputs `meas_4a.out`, `meas_4b.out`, `meas_4c.out`, `stage2_trials/SUMMARY.txt` in the scratchpad.

Target (Lee): the compiler generally stays under 4 GB physical footprint (Activity Monitor) with no swapping for more than 30 s; benchmark = the self-build, memory first, then time.
Caveat on every number below: they are peak RSS from the wrapper (`time -l` style), not Activity Monitor footprint, and none is a self-build. Compressed and swapped pages are not in RSS.

## 1. Did the stack model reduce per-unit memory? (facts)

Per unit, old 999939 vs stage 2 (stage 2 = this source built by stage 1):

| unit | old MB | stage 2 MB | ratio | old s | stage 2 s |
| --- | --- | --- | --- | --- | --- |
| emitter_core | 3585 | 606 | 0.17 | 9.28 | 10.53 |
| wbt_map | 2731 | 1169 | 0.43 | 8.26 | 8.22 |
| tc_expressions_actor_spawn | 4389 | 1196 | 0.27 | 9.47 | 9.25 |
| tc_actor_supervision_messaging | 2197 | 729 | 0.33 | 4.53 | 4.78 |
| tc_binary_ops | 2379 | 708 | 0.30 | 4.78 | 5.08 |

* Yes on all five: 2.3x to 5.9x lower (ratio 0.17 to 0.43). Time is within about 13 percent (emitter_core +13 percent, others within 6 percent).
* Against stage 1 (Phase3_notes section 8: 256 / 471 / 515 / 328 / 305 MB at 10-20x the time), stage 2 is 1.7-2.5x larger in RSS but 10-20x faster. Time went back to the old level; the RSS between stage 1 and stage 2 moved the other way (stage 1 and 2 differ in the compiler's own code: stage 1 was built without the Step B rule).
* Every unit is under 1.2 GB, so these five meet 4 GB with margin. wbt_map is the least improved (0.43).
* Gate: run_FAIL = 0 in all 12 suites (functions 666, records 458, tuples 635, list 537, string 671, memory_region 423, actors 368, carriers 37, supervisors 115, actor_stacks 11 run_ok; error_enforcement and ordered_data_structures no run failures). The exit-2 suites are `.sams`-vs-`.ascomp` drift only (asm_diff: records 25, tuples 4, memory_region 8, actors 380, carriers 62, supervisors 154, actor_stacks 13; ordered_data_structures has 18 stale goldens, other_FAIL=18). functions, list, string, error_enforcement exit 0. Drift is expected from the new adoption code; the goldens need a check by Lee's rule, not regeneration here.

## 2. Does the WHOLE parse batch meet the target?

Parser batch (generated single file of k functions, about 18 tokens each):

| k | tokens | stage 2 s | stage 2 MB | stage 2 exit | old 999939 s | old MB | stage2/old MB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1250 | 22.5k | 0.89 | 356 | 0 | 0.5 | 900 | 0.40 |
| 2500 | 45k | 3.04 | 1310 | 0 | 1.6 | 3000 | 0.44 |
| 5000 | 90k | 11.33 | 5042 | 0 | 5.9 | 6300 | 0.80 |
| 10000 | 180k | 45.35 | 5444 | 70 | 24.9 | 7000 | 0.78 |

(Old numbers are the rounded GB figures in Phase3_notes section 8.)

What the data say:
* No, not at the top. k=5000 is 5.0 GB, above 4 GB; k=10000 reaches 5.4 GB and then ends in exit 70, a runtime failure (not success, cause not captured in the file).
* RSS grows about 3.7x per doubling (356 -> 1310 -> 5042), i.e. roughly n^1.9, quadratic. Time grows 3.4x, 3.7x, 4.0x per doubling, also quadratic, in both models (old: 3.2x, 3.7x, 4.2x). So the parser allocates O(n^2) bytes in time O(n^2), and in the stack model a growing share of that is still resident.
* The live data is linear (tokens, AST) and cannot be 5 GB: bytes per token rise 16 KB, 29 KB, 56 KB. Nearly all of the 5 GB is not live.
* The advantage over the old model shrinks with size (0.40, 0.44, 0.80): the larger the input, the more of the quadratic allocation stays resident. The old model also flattens at 6-7 GB, and stage 2 at 5.0-5.4 GB; both saturate, which suggests a ceiling (memory pressure, compression, or a fault) rather than the real demand. This is not established by these data.
* Time at the top is 1.8x slower than old (11.33 vs 5.9 s; 45.35 vs 24.9 s).
* Reading for the target: per-unit self-build units measured so far are under 1.2 GB, but a single unit whose parse is large already costs 1.3 GB at 45k tokens. Using the n^1.9 fit (rough, three points) 4 GB is reached near 80k tokens in one file. Whether any self-build unit or the stdlib batches (ordered_data_structures units that took 61 s earlier) are that large is not known: token counts per unit are not measured.

Candidates ranked against this data (theory from `Phase3_memory_analysis.md` section 3):

| rank | candidate | fit with the data |
| --- | --- | --- |
| 1 | Adopted garbage (option-1 retention: a callee's whole dynamic part stays until the outermost consumer) | Best. Needs a quadratic quantity: a chain of n levels each holding O(n) rebuilt data (list rebuilds, lift_decl_list records, append_decl_lists) retains n x n. Matches quadratic RSS and the shrinking gap to the old model (old model retains everything; adoption retains an increasing share). Section 7 of Phase3_notes names exactly these functions as still evacuating or adopting. |
| 2 | High-water without return | Explains why a transient is resident to the end of the unit; cannot by itself produce a quadratic term, because one evacuation transient is the size of the value (linear). Needed to explain "peak stays", not the growth. Also the one-dispatch-per-unit structure means no release ever runs. |
| 3 | Evacuation scratch | Linear in the evacuated value; large only if the value is large. Explains time (quadratic copying), not 5 GB, unless the evacuated list is hundreds of MB. Weak. |
| 4 | Fixed frames times depth | Linear in depth (k to 10 x k levels). Gives 16 KB/token at k=1250 only if frames were huge; cannot give the 3.7x per doubling. A linear base term at most. |
| 5 | Interim heap (messages, replies, state shell) | Unchanged from the old model, per dispatch, not quadratic here. A floor, not the growth. |
| 6 | Reservations | Virtual, cannot raise RSS. Ruled out by the RSS figures. They may raise Activity Monitor footprint display only if counted as VSZ; not measured. |

Caution: the ranking is an inference from shape (quadratic) and the old-vs-new ratio, not from an attribution measurement. Nothing here measured retained adopted bytes directly.

## 3. Shapes (scaling probe, stage 2, best of three ns, n = 2500, 5000, 10000, 20000)

Shape ids from `scale.silica`: 1 parameter form `cons(x, f(t))`; 2 let-bound list through one intermediate call; 3 let-bound result used in return position and also read; 4 tail-call loop; 5 parser shape (`rest <- f(t); cons(x, rest)`); 6 lambda-lift record (result bound, fields projected, record rebuilt).

| shape | 2500 | 5000 | 10000 | 20000 | ratio per doubling | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 96k | 193k | 393k | 776k | 2.01, 2.04, 1.97 | linear |
| 2 | 109k | 208k | 447k | 1230k | 1.91, 2.15, 2.75 | rising: super-linear at the top |
| 3 | 106k | 104k | 215k | 728k | 0.98, 2.07, 3.39 | rising steeply: approaching 4x |
| 4 | 85k | 173k | 352k | 625k | 2.04, 2.03, 1.78 | linear |
| 5 | 81k | 170k | 350k | 604k | 2.10, 2.06, 1.73 | linear |
| 6 | 94k | 203k | 379k | missing | 2.16, 1.87 | incomplete (see below) |

* Shape 2 and shape 3 are the super-linear ones. Shape 3 at 20000 is 3.4x its 10000 time; shape 2 is 2.75x. If the trend is real these are quadratic with a high crossover.
* Shapes 1, 4, 5 are linear (ratios about 2.0, falling below 2 at the top, which is consistent with fixed costs, not a rise). Shape 6 is linear on the three points it has.
* Shape 6 is incomplete: the file ends after the 10000 line (n=20000 line absent). The script printed `run exit=70`, so the shapes binary ended in a runtime failure, plausibly during shape 6 at n=20000, which would be the same exit code as the k=10000 parser batch. That is an inference from where the output stops, not an observed message. `peakRSS_MB=9` in this file is not usable (the wrapper measured something other than the shapes process).
* How firm: four points per shape, one run, best of three inside each point. Shape 3's first doubling (106k -> 104k) is flat, which shows noise or a fixed floor of at least 2 percent-scale at small n; a 2.75x or 3.4x on one doubling could be a cache or page-commit threshold rather than a complexity class. To make it firm:
  * more sizes (2500 to 160000 or until the failure), at least 6 doublings, so the log-log slope can be fitted;
  * repeats (5 runs per point, report min and median, separate processes);
  * record footprint per point, not only time, so a memory threshold is separable from complexity;
  * capture the exit-70 banner for the failing point.

## 4. Did the new rule (option 1 plus shapes i and ii) avoid the blow-up for the parser shapes?

* Probe, yes for shape 1 and shape 5: both are linear to n=20000 (about 2.0x and 1.7-2.1x per doubling). Shape 5 is the parser shape, shape 1 the case that needs rule (i).
* Comparison with the old model for these shapes: not available. The earlier notes never measured the four shapes (the probe was rejected with E3010 in section 8, "the four shapes were not measured"), and no 999939 run of them exists. What the earlier notes do show is the effect on the real parser: with the pre-Step-B rule the k=2500 compile ran over 600 s, and stage 1 was 96 s at k=1250. Stage 2 does k=1250 in 0.89 s and k=10000 in 45 s, so the hang is gone. That is a comparison on the parser batch, not on the shapes.
* But the real parser batch is still quadratic in time and memory (section 2), so the blow-up is only partly avoided: no longer a hang, still quadratic. The two shapes that are linear in the probe do not explain this. Candidate sources of the remaining quadratic term are the shapes that still rise (2 and 3) and the lambda-lift record shape (6, whose top point is missing), plus `append_decl_lists` / `lift_decl_list`. Which function is responsible has not been sampled on stage 2. The earlier sample (Phase3_notes section 7) was on a different compiler.
* The stack model did not make the old model's quadratic allocation disappear, only moved part of it from heap garbage to retained adopted garbage.

## 5. What must be measured next, and the decision for Lee

Measure (no fix chosen here):
1. Self-build footprint over time, stage 2, one process per unit, 1 s sampling of footprint (Activity Monitor figure, not RSS), with the swap/compression state recorded. Section 8 of `Phase3_memory_analysis.md` is that request; it has not produced a self-build number yet. The largest unit and the footprint peak per unit are the target numbers.
2. Token count per self-build unit (to place real units on the k curve) and the largest unit's phase timeline (lex, parse, check, SIR, emit): which phase carries the peak.
3. Stage 2 parser batch with finer sizes (k = 1250, 1800, 2500, 3500, 5000), footprint, repeats; capture the exit-70 banner at k=10000 and at the shape-6 point. Establish whether 5.0-5.4 GB is a ceiling or the real demand.
4. Attribution: sample stage 2 on k=2500 to name the functions (lift_decl_list? append_decl_lists?); and counters for committed stack bytes at the peak and adopted bytes retained, to separate adopted garbage (candidate 1) from high-water (2) and scratch (3).
5. The shape probe with more sizes and repeats, plus shape 6 to completion, plus footprint per point (section 3).
6. Gather G and R at the return of the hot builders (the threshold input the amendment says is an open measurement).

Decisions for Lee:
* Which number is the pass criterion: the self-build's maximum per-unit footprint (the stated benchmark), or the synthetic parse batch. On the per-unit data the target is already met for five units; on the batch it is not.
* Whether the remaining quadratic parse time and memory is in scope before the target is declared met or not (it cost 11 s and 5 GB at 90k tokens).
* Which direction to take the 3.3/3.4 amendment and the actor-split direction forward, and in what order, given that the data point to retained adopted garbage and a high-water that is never returned inside a dispatch; the threshold of the copy-or-keep rule is unmeasured.
* How to treat the exit-70 failures (k=10000 parse, probable shape-6 n=20000): a stack-policy limit, a memory ceiling, or a defect. They need a captured message before any memory conclusion is drawn from the runs that end in them.
* Whether the stale goldens (about 666 asm drifts across the exit-2 suites, plus 18 ordered_data_structures) should be reviewed now or after the memory work, since further codegen changes will move them again.
