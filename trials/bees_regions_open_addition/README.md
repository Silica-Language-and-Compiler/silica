# bees_regions_open_addition (INTEGRATE_PENDING)

Open region-release defects, staged as trials that state the correct behaviour. The
`INTEGRATE_PENDING` file keeps this directory out of tree-wide runs on the host and on the board
(both report it as `SKIPPED (INTEGRATE_PENDING)`), so the trials do not turn the gate red while the
defects are open. Run them by hand:

```
make -C bees_regions_open_addition integrate TRIAL_TARGET=host                 # from trials/
make integrate TRIAL_TARGET=host TRIAL_SUITES=bees_regions_open_addition       # same, through the tree runner
```

| trial | shows |
|---|---|
| `bees_sd7_message_region_released` | project-bees SD-7, region design §18.7: 100,000 casts each carrying a fresh two-cell region; each region should be released when the receiving behaviour returns. |
| `region_in_returned_record_released` | hazard H9, no actors: 100,000 calls each returning a record that holds a fresh two-cell region; each region should be released when the caller is done with it. |

Status 2026-10-22 (Mac, `binaries/silica-compiler` = 999943): both leak. Their output is right
(`300000` / `done` and `5000050000`), but peak RSS is ~545 MB and ~528 MB (519.9 and 503.4 MiB), about
5 KB a region; the int64-cast control for SD-7 peaks at ~14.6 MB.

## How the leak is checked: `.scout` plus a peak-RSS ceiling

The leak shows only in memory, and no program output can tell it today:

- `heap_used()` counts actor arena bumps (`_silica_rt_region_alloc`) only. `alloc_region` takes its
  block from `_silica_rt_raw_alloc` (malloc), which no counter sees: `heap_used()` grew by 0 over the
  100,000 returned-record regions and by 56 bytes a message (the message copies) in SD-7.
- `get_actor_memory_usage` reports actor stacks only.

So each trial has a `.scout` with the correct output and a `<trial>.max_rss_mb` marker (the
harness's peak-memory ceiling, `../README.md`, "Peak memory ceiling"). A pass needs both: matching
output and a peak resident set size at or below the ceiling.

| trial | `.scout` | ceiling | leak-free run | today (999943) |
|---|---|---|---|---|
| `bees_sd7_message_region_released` | `300000`, `done`, `0` | 100 MB | ~15 MB (the int64-cast control; also the Python marker runner's own peak) | ~520 MiB (~545 MB; 519.9 and 521.1 in two runs) |
| `region_in_returned_record_released` | `5000050000`, `0` | 100 MB | a few MB (about one region live) | 503.4 MiB (~528 MB) |

100 MB is more than six times a leak-free run and a fifth of today's peak, so normal variation
(allocator, carrier count, a slower host) does not flip a leak-free run, and a leak a fifth the
size of today's still fails. SD-7 caveat: `main` casts all 100,000 messages without throttling, so
if the receiver falls far behind, many messages and their regions are in flight at once even with
correct release; the ceiling assumes the receiver keeps up (it does with int64 messages). If a fixed
compiler still trips the ceiling with flat per-dispatch memory, throttle the sender rather than
raise the ceiling.

Run today (Mac, 999943), the output matches and both trials fail on the ceiling; with no `.ascomp`
each also reports `has no .ascomp file`:

```
❌❌ bees_regions_open_addition/bees_sd7_message_region_released has no .ascomp file
❌❌ bees_regions_open_addition/region_in_returned_record_released has no .ascomp file
❌ bees_regions_open_addition/bees_sd7_message_region_released: max_rss_mb: peak resident set size 519.9 MB exceeds the ceiling of 100 MB (bees_sd7_message_region_released.max_rss_mb)
❌❌ bees_regions_open_addition/bees_sd7_message_region_released .sout differs from .scout
❌ bees_regions_open_addition/region_in_returned_record_released: max_rss_mb: peak resident set size 503.4 MB exceeds the ceiling of 100 MB (region_in_returned_record_released.max_rss_mb)
❌❌ bees_regions_open_addition/region_in_returned_record_released .sout differs from .scout
```

There is no `.ascomp`: today's assembly is the defective codegen, so it is recorded only when the
leak is fixed. The ceiling is host only; the board ignores the marker, so a board run would need a
program-visible counter (a runtime count of `alloc_region` blocks in `heap_used()`, or a builtin such
as live region bytes; compiler work) to check the leak there.

When a defect is fixed and its trial passes on every host (output and ceiling), add its `.ascomp`
goldens (Mac, then `linux_aarch64` on pix and `linux_x86_64` on nix) and move it, with its
`.scout` and `.max_rss_mb`, to `../bees_regions_addition` (re-check that suite's other `.ascomp` goldens, which a
new shape can renumber), then delete
this directory once it is empty. The SD-22 trial in `../bees_regions_addition` must still pass
after these are fixed: it is the check that the release does not come back as a scope-exit free.
