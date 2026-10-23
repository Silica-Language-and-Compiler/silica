# bees_regions_addition

Trials ported from the project-bees defect repros (`project-bees/trials/silica_defects/`, ported to
current syntax on 2026-10-22; see `docs/participate.md`, BEES set step 0). They are regions and
aggregates inside actors. Each trial keeps the port's own FailureReporter (`start_reporter`)
instead of `trial_support_*`, so the program is the one BEES ran.

They have a directory of their own because every suite compiles all its units in one batch with
one shape and atom table, and helper modules (here `bees_term`) are linked into every trial of a
suite: adding these to `actors_addition` or `memory_region_addition` would add record and tuple
shapes and a helper module that renumber or change those suites' `.ascomp` goldens.
`memory_region_addition`'s Makefile also has no `.wait_for_exit` runner or helper-module link.

| trial | shows |
|---|---|
| `bees_sd21_aggregate_return_does_not_leak_stack` | SD-21: 100,000 dispatches x 10 record-returning calls; the actor's stack `high_water` (from `get_actor_memory_usage`) does not grow after message 99000 (prints `false`). |
| `bees_sd22_region_bound_locally_cast` | SD-22 (hazard H2): a locally bound region moved into a cast is not freed at scope exit; three messages read `1 2 3`, not `333`. Caveat: the region travels inside a record, which is never released (H9), so the pass may come from that leak rather than from a correct move. |
| `bees_term` (helper) | project-bees's `bees_term` module, unchanged; used by the SD-22 trial. |

SD-20 (a function returning `(region, ref)` called on an actor thread) has no trial here: it is
already covered by `../memory_region_addition/region_tuple_return_in_actor`, so the ported
`bees_sd20_region_tuple_return_in_actor` was dropped as a duplicate. SD-21's trial is kept because
it adds a real stack leak check (the actor's `high_water` must not grow) beyond
`../actors_addition/aggregate_return_in_actor_keeps_stack`, which detects only the fault.

Status 2026-10-22 (Mac, `binaries/silica-compiler` = 999943): both trials pass.

Goldens: `.scout` (shared by every target) and the Mac `.ascomp` come from real Mac output. Still
needed: `<unit>.linux_aarch64.ascomp` (pix) and `<unit>.linux_x86_64.ascomp` (nix) for all three units,
and a board run (`TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=bees_regions_addition`) to see whether the
plain `.scout` holds there. The SD-21 trial's 100,000 queued casts probably do not fit the board heap,
the same as `actors_addition/aggregate_return_in_actor_keeps_stack` (listed in
`targets/ESP32-S3_raw.skip`).

The trials that still fail (SD-7, and the returned-record region leak) are in
`../bees_regions_open_addition` (INTEGRATE_PENDING).
