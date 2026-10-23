# bees_regions_open_addition (INTEGRATE_PENDING)

Open region-release defects, staged as trials that state the correct behaviour. The
`INTEGRATE_PENDING` file keeps this directory out of tree-wide runs on the host and on the board
(both report it as `SKIPPED (INTEGRATE_PENDING)`), so the trials do not turn the gate red while the
defects are open. Run them by hand:

```
make -C bees_regions_open_addition integrate                 # from trials/
make integrate TRIAL_SUITES=bees_regions_open_addition       # same, through the tree runner
```

| trial | shows |
|---|---|
| `bees_sd7_message_region_released` | project-bees SD-7, region design §18.7: 100,000 casts each carrying a fresh two-cell region; each region should be released when the receiving behaviour returns. |
| `region_in_returned_record_released` | hazard H9, no actors: 100,000 calls each returning a record that holds a fresh two-cell region; each region should be released when the caller is done with it. |

Status 2026-10-22 (Mac, `binaries/silica-compiler` = 999943): both leak. Their output is right
(`300000` / `done` and `5000050000`), but peak RSS (`/usr/bin/time -l`) is ~545 MB and ~528 MB, about
5 KB a region; the int64-cast control for SD-7 peaks at ~14.6 MB.

## Why there is no `.scout` yet

The leak shows only in memory, and no program output can tell it today:

- `heap_used()` counts actor arena bumps (`_silica_rt_region_alloc`) only. `alloc_region` takes its
  block from `_silica_rt_raw_alloc` (malloc), which no counter sees: `heap_used()` grew by 0 over the
  100,000 returned-record regions and by 56 bytes a message (the message copies) in SD-7.
- `get_actor_memory_usage` reports actor stacks only.

A `.scout` written now would be the output a leaking program already prints, so the trials would
pass while leaking. With no `.scout` and no `.ascomp`, a named run reports both as failures.

One of these is needed before the `.scout` can be written:

1. **A runtime counter (compiler work, Fable):** count `alloc_region` blocks in `heap_used()` (add on
   `_silica_rt_raw_alloc` for regions, subtract in `_silica_rt_region_destroy`), or add a builtin
   such as live region bytes. The trials then print the growth between an early and a late point,
   and the `.scout` holds `0`, the same pattern as `actors_addition/zero_heap_growth_*`. This works
   on the board too.
2. **A harness RSS ceiling (harness work):** a marker such as `<trial>.max_rss_mb` that runs the
   trial under `/usr/bin/time -l` (macOS) or `/usr/bin/time -v` (Linux) and fails above the bound
   (for example 64 MB against ~530 MB today). Host only; the board needs option 1.

When a defect is fixed and its trial passes on every host, add its `.scout` and `.ascomp` goldens
and move it to `../bees_regions_addition` (re-check that suite's other `.ascomp` goldens, which a
new shape can renumber), then delete
this directory once it is empty. The SD-22 trial in `../bees_regions_addition` must still pass
after these are fixed: it is the check that the release does not come back as a scope-exit free.
