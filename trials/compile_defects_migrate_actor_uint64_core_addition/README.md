# compile_defects_migrate_actor_uint64_core_addition (INTEGRATE_PENDING)

One valid Silica program that today's compiler rejects, staged from the project BEES triage
(2026-10-23); see `../bees_gaps_open_addition/README.md` for the whole set and
`../compile_defects_addition/README.md` for why a compile-time defect gets a directory of its own.

- `migrate_actor_uint64_core`: `migrate_actor(a, core)` with `core: uint64`. Spec §15.1.2 and §15.1.2.4 declare `migrate_actor(actor_ref, target_core: uint64)`; today the type checker accepts only an int64 core and reports E2003 "type mismatch: core". The same program with `core: int64` compiles and prints the expected output.

| repro (triage scratch `bees_triage/`) | today (stable BEES-triage compiler, Mac, 2026-10-23) | `.scout` (correct behaviour) |
|---|---|---|
| sd19u | E2003 at line 32 | `ok`, `done`, `0` |

`INTEGRATE_PENDING` keeps this directory out of tree-wide runs on the host and on the board. Run it by hand:

```
make -C compile_defects_migrate_actor_uint64_core_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler   # from trials/
```

When the compiler accepts it and the output matches the `.scout`, move the trial to `actors_addition` with
`.ascomp` goldens, record the Linux goldens, and delete this directory.
