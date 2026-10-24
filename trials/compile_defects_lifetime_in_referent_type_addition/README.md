# compile_defects_lifetime_in_referent_type_addition (INTEGRATE_PENDING)

One valid Silica program that today's compiler rejects, staged from the project BEES triage
(2026-10-23); see `../bees_gaps_open_addition/README.md` for the whole set and
`../compile_defects_addition/README.md` for why a compile-time defect gets a directory of its own.

- `lifetime_in_referent_type`: SD-6. `count/1` takes `ref(L, normal, (atom, int64, ref?(L, normal, rec)))` and main passes a `ref(M, ...)` of the same shape. Spec §12.1.4 (decision Q10 a): lifetime names in a signature are quantified per signature and instantiated at each call, consistently across arguments and result, so L := M applies inside the referent type too. Today: E2003 "type mismatch: cell". `memory_region_addition/lifetime_parameter_name` covers only the top-level case (`ref(L, normal, int64)`), which compiles since 2026-09-24; renaming M to L here makes this program compile and print the expected output.

| repro (triage scratch `bees_triage/`) | today (stable BEES-triage compiler, Mac, 2026-10-23) | `.scout` (correct behaviour) |
|---|---|---|
| sd6 | E2003 at line 32 | `7`, `0` |

`INTEGRATE_PENDING` keeps this directory out of tree-wide runs on the host and on the board. Run it by hand:

```
make -C compile_defects_lifetime_in_referent_type_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler   # from trials/
```

When the compiler accepts it and the output matches the `.scout`, move the trial to `memory_region_addition` (next to `lifetime_parameter_name`) with
`.ascomp` goldens, record the Linux goldens, and delete this directory.
