# compile_defects_ffi_same_unit_adapter_addition (INTEGRATE_PENDING)

One valid Silica program that today's compiler rejects, staged from the project BEES triage
(2026-10-23); see `../bees_gaps_open_addition/README.md` for the whole set and
`../compile_defects_addition/README.md` for why a compile-time defect gets a directory of its own.

- `dangerous_ffi_same_unit_adapter`: a worker behaviour's `sequence proc[external_danger, concurrency]` calls `add/2`, an adapter in the same `dangerous_*` unit that wraps the foreign `silica_legacy_math_add_int64`. FFI spec §4.5 requires `external_danger` around any call into a `dangerous_*` module (its own adapters included) and §3.3 gives the adapter shape; today the effect checker reports E3010 "unused effect declaration: external_danger" on the worker (line 42), so the program cannot be written at all. The same call qualified into another `dangerous_*` unit compiles (`ffi_addition/app_cast_worker_legacy_add`). The adapter binds its result first so the trial does not also hit the tail-call fault (`bees_gaps_open_addition/dangerous_ffi_adapter_tail_call`).

| repro (triage scratch `bees_triage/`) | today (stable BEES-triage compiler, Mac, 2026-10-23) | `.scout` (correct behaviour) |
|---|---|---|
| sd15c | E3010 at line 42 (plus the usual W4001 FFI warning) | `5`, `done`, `0` |

`INTEGRATE_PENDING` keeps this directory out of tree-wide runs on the host and on the board. Run it by hand:

```
make -C compile_defects_ffi_same_unit_adapter_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler   # from trials/
```

The Makefile links `dangerous_exposure_source` to the ffi_addition fixtures view for this platform and passes the
archives the compiler lists in `silica.link` to the linker; run `make -C ffi_addition fixtures` first if the archives are missing.

When the compiler accepts it and the output matches the `.scout`, move the trial to `ffi_addition`, as an `app_*` trial (its own directory with `silica.link.scout`) with
`.ascomp` goldens, record the Linux goldens, and delete this directory.
