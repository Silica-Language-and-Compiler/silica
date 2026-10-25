# compile_defects_case_512_arms_addition (INTEGRATE_PENDING)

One valid Silica program that today's compiler rejects, staged from the project BEES triage
(2026-10-23); see `../bees_gaps_open_addition/README.md` for the whole set and
`../compile_defects_addition/README.md` for why a compile-time defect gets a directory of its own.

- `case_512_literal_arms`: `id_of/1` is one flat `case` over an int64 with 512 literal arms (0 to 511) and a catch-all. Nothing in spec §3.3.3 or §3.6.4 limits the number of arms; today the parser reports E1069 "function 'id_of' has no parsable body". With 511 literal arms the same program compiles and runs correctly, so the limit is exactly 512.

| repro (triage scratch `bees_triage/`) | today (stable BEES-triage compiler, Mac, 2026-10-23) | `.scout` (correct behaviour) |
|---|---|---|
| arms | E1069 | `p3 ok`, `p511 ok`, `overflow ok`, `0` |

`INTEGRATE_PENDING` keeps this directory out of tree-wide runs on the host and on the board. Run it by hand:

```
make -C compile_defects_case_512_arms_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler   # from trials/
```

When the compiler accepts it and the output matches the `.scout`, move the trial to `case_addition` with
`.ascomp` goldens, record the Linux goldens, and delete this directory.
