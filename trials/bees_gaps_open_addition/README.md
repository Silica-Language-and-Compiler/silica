# bees_gaps_open_addition (INTEGRATE_PENDING)

Failing-before trials for runtime gaps found in the project BEES triage (2026-10-23) that are not
being fixed now (memory rule: no covering trial means write one, even when the fix is deferred).
Each `.scout` is the hand-derived output of the **correct** behaviour, so the trials fail with
today's compilers and pass once the defect is fixed. The `INTEGRATE_PENDING` file keeps this
directory out of tree-wide runs on the host and on the board (both report it as
`SKIPPED (INTEGRATE_PENDING)`), so the gate stays green while the defects are open. Run them by hand:

```
make -C bees_gaps_open_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler   # from trials/
make integrate TRIAL_TARGET=host TRIAL_SUITES=bees_gaps_open_addition                                                     # through the tree runner
```

The harness ignores `SILICA_COMPILER` from the environment; pass it on the make command line.
The FFI trial links the `ffi_addition` wrapper archives: the Makefile links
`dangerous_exposure_source` to `../ffi_addition/fixtures/build/<platform>/dangerous_exposure_source`
(as the ffi_addition app trials do) and passes the archives the compiler lists in `silica.link`
to the linker. If the archives are missing, run `make -C ffi_addition fixtures` first.

"Today" is the stable compiler copy used for the BEES triage (Mac, 2026-10-23), from
`make -C bees_gaps_open_addition integrate` and from runs of the built binaries. Repros are in the
triage scratch directory `bees_triage/<name>`.

| trial | defect | spec | repro | today | expected |
|---|---|---|---|---|---|
| `monitor_down_delivered` | an actor that monitors a peer never receives `(:down, monitor_ref, actor_ref, failure_reason)` when the peer dies | §15.4.8.6 (DOWN goes to the standard mailbox) | `s1q2_info`, `s1q2_info2` | **fails every run**: `watching`, `failure report: peer`, `no down message`, status 1 (the ticker's timeout fires; no DOWN ever arrives) | `watching`, `failure report: peer`, `down`, `0` (multiset compare: the report and the DOWN race) |
| `dangerous_ffi_adapter_tail_call` (+ helper unit `dangerous_tail_adapter`) | an FFI adapter whose guarded foreign call is in tail position (`fn add(l, r) -> int64 { add_raw(l, r) }`) faults: the tail-call path emits the epilogue before the guarded foreign call and clobbers X30 | FFI wrapper spec §3.3 (adapter shape) | `sd17a` (faults), `sd17a2` (works when the result is bound first) | **fails every run**: `[silica] fault at ... in dangerous_tail_adapter_add+0x6c ...`, status 70 | `5`, `done`, `0` (checked against the bound-first control, which prints exactly that) |

`monitor_down_delivered` cannot hang: the failure reporter starts a ticker on the peer's report,
which casts itself 200,000 times (about 0.4 s on the Mac) and then sends the watcher
`(:timeout, n)`; the watcher prints `no down message` and ends main with `cast_exit(1)`. A DOWN that
arrives first ends main with `cast_exit(0)` instead. The ticker casts to itself by name
(`cast_registered`), because `cast(ref, ...)` as a case arm body was a separate compile defect when
this trial was written (fixed 2026-10-23; trial `actors_addition/cast_in_case_arm`).

All the units here compile in one batch, so the helper unit `dangerous_tail_adapter.o` is linked
into both executables; it is harmless in `monitor_down_delivered`.

## Compile-rejection gaps from the same triage

A trial the compiler rejects aborts its suite's batch compile, so each of these lives alone in its
own `compile_defects_<slug>_addition` directory (memory note "compile-defect trials need their own
directory"), also `INTEGRATE_PENDING`, with its own README. All are valid programs with a `.scout`
of the correct output.

| directory | trial | defect | spec | repro | today |
|---|---|---|---|---|---|
| `../compile_defects_ffi_same_unit_adapter_addition` | `dangerous_ffi_same_unit_adapter` | a worker's `external_danger` sequence calling a same-unit `dangerous_*` adapter is E3010 "unused effect external_danger" | FFI spec §3.3, §4.5 (the effect is required) | `sd15c` | E3010 (line 42) |
| `../compile_defects_case_512_arms_addition` | `case_512_literal_arms` | a `case` with 512 or more literal arms is E1069 "no parsable body" (511 + catch-all compiles) | §3.3.3, §3.6.4 | `arms` | E1069 |
| `../compile_defects_migrate_actor_uint64_core_addition` | `migrate_actor_uint64_core` | `migrate_actor(ref, core)` accepts only an int64 core; the spec declares `target_core: uint64` | §15.1.2, §15.1.2.4 | `sd19u` | E2003 "type mismatch: core" |
| `../memory_region_addition` (fixed 2026-10-25, chunk 15 phase 1; was `../compile_defects_lifetime_in_referent_type_addition`) | `lifetime_in_referent_type` | SD-6: a lifetime inside the referent type (`ref(L, normal, (atom, int64, ref?(L, normal, rec)))`) is matched by name, so a `ref(M, ...)` argument is E2003 | §12.1.4 (decision Q10 a) | `sd6` | E2003 "type mismatch: cell" |
| `../actors_addition` (fixed 2026-10-23; was `compile_defects_cast_in_case_arm_addition`) | `cast_in_case_arm` | `cast(ref, msg impl ActorMessage {})` as a case arm body was E2005 (first arm) or E1069 (last arm): the case-arm RHS parser took only identifiers as call heads, not callable keywords; found while writing `monitor_down_delivered` | §3.3.11, §3.3.3 | (this suite) | was E2005 (line 31) |

SD-6 note: `memory_region_addition/lifetime_parameter_name` (fixed 2026-09-24) covers the top-level
case, `ref(L, normal, int64)` against `ref(L1, normal, int64)`; no trial covered a lifetime nested in
the referent type, so `lifetime_in_referent_type` was added.

## When a defect is fixed

Move the trial (and its helper unit) to the suite matching its topic, with `.ascomp` goldens
(`actors_addition` or `supervisors_addition` for the monitor trial; `ffi_addition` as an `app_*`
trial for the FFI ones; `case_addition`; `actors_addition`; `memory_region_addition`), record the
Linux goldens, and delete the staged copy (and this directory once it is empty).
