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
| `bees_sd7_message_region_released` | project-bees SD-7, region design §18.7, the realistic burst shape: `main` casts 100,000 messages at once, each carrying a fresh two-cell region; each region should be released when the receiving behaviour returns. Output check only. |
| `bees_sd7_message_region_released_in_flight` | the same release, measured with one message in flight: the behaviour casts the next region message to itself, 100,000 times. Carries the SD-7 peak-RSS ceiling. |
| `region_in_returned_record_released` | hazard H9, no actors: 100,000 calls each returning a record that holds a fresh two-cell region; each region should be released when the caller is done with it. |

## How the leak is checked: `.scout` plus a peak-RSS ceiling

The leak shows only in memory, and no program output can tell it today:

- `heap_used()` counts actor arena bumps (`_silica_rt_region_alloc`) only. `alloc_region` takes its
  block from `_silica_rt_raw_alloc` (malloc), which no counter sees: `heap_used()` grew by 0 over the
  100,000 returned-record regions and by 56 bytes a message (the message copies) in SD-7.
- `get_actor_memory_usage` reports actor stacks only.

So a leak trial has a `.scout` with the correct output and a `<trial>.max_rss_mb` marker (the
harness's peak-memory ceiling, `../README.md`, "Peak memory ceiling"). A pass needs both: matching
output and a peak resident set size at or below the ceiling. The harness peak includes the Python
marker runner's own ~15 MB.

### Why SD-7 has two trials

In the burst trial every queued message legitimately holds its live ~4 KB region, so its peak RSS
measures queue depth as well as release: with the SD-7 fix it still peaks at ~382 MiB, because the
receiver falls behind and the queue holds most of the regions. It cannot tell a leak from a full
queue, so it has no ceiling and checks output only; it stays because it is the realistic shape
(and the shape the BEES repro had). The in-flight twin keeps at most one message, and so one region,
alive at a time; memory that grows with the count there is memory never released, so it carries
the ceiling.

| trial | `.scout` | ceiling | without the fix (999943) | with the fix (Mac build) |
|---|---|---|---|---|
| `bees_sd7_message_region_released` | `300000`, `done`, `0` | none (queue depth) | ~520 MiB (~545 MB) | ~382 MiB (the queue) |
| `bees_sd7_message_region_released_in_flight` | `300000`, `done`, `0` | 40 MB | 508.9 MiB (~534 MB alone) | 15.7 MiB (~6.9 MB alone) |
| `region_in_returned_record_released` | `5000050000`, `0` | 100 MB | 503.4 MiB (~528 MB) | 503.4 MiB, not fixed |

"Alone" is `/usr/bin/time -l` on the program without the harness. The in-flight ceiling of 40 MB is
about 2.5 times its leak-free harness peak and under a tenth of the leak, so normal variation does
not flip a leak-free run, while a leak of about 250 bytes a message still fails. The returned-record
ceiling of 100 MB is more than six times a leak-free run (a few MB, about one region live) and a
fifth of today's peak.

Runs on the Mac, 2026-10-22, from `trials/`. The harness ignores `SILICA_COMPILER` from the
environment; pass it on the make command line.

Without the SD-7 fix (`binaries/silica-compiler` = 999943, the default):

```
make -C bees_regions_open_addition integrate TRIAL_TARGET=host
❌❌ bees_regions_open_addition/bees_sd7_message_region_released_in_flight has no .ascomp file
❌❌ bees_regions_open_addition/bees_sd7_message_region_released has no .ascomp file
❌❌ bees_regions_open_addition/region_in_returned_record_released has no .ascomp file
❌ bees_regions_open_addition/bees_sd7_message_region_released_in_flight: max_rss_mb: peak resident set size 508.9 MB exceeds the ceiling of 40 MB (bees_sd7_message_region_released_in_flight.max_rss_mb)
❌❌ bees_regions_open_addition/bees_sd7_message_region_released_in_flight .sout differs from .scout
❌ bees_regions_open_addition/region_in_returned_record_released: max_rss_mb: peak resident set size 503.4 MB exceeds the ceiling of 100 MB (region_in_returned_record_released.max_rss_mb)
❌❌ bees_regions_open_addition/region_in_returned_record_released .sout differs from .scout
```

(The burst trial's output matched there too.) With the SD-7 fix (the Mac build at
`compiler/build/apple_silicon_mac/silica-compiler`):

```
make -C bees_regions_open_addition integrate TRIAL_TARGET=host SILICA_COMPILER=/Volumes/2T/silica/compiler/build/apple_silicon_mac/silica-compiler
❌❌ bees_regions_open_addition/bees_sd7_message_region_released_in_flight has no .ascomp file
❌❌ bees_regions_open_addition/bees_sd7_message_region_released has no .ascomp file
❌❌ bees_regions_open_addition/region_in_returned_record_released has no .ascomp file
✅ bees_regions_open_addition/bees_sd7_message_region_released_in_flight peak resident set size 15.7 MB is within the ceiling of 40 MB
✅✅ bees_regions_open_addition/bees_sd7_message_region_released_in_flight output matches .scout
✅✅ bees_regions_open_addition/bees_sd7_message_region_released output matches .scout
❌ bees_regions_open_addition/region_in_returned_record_released: max_rss_mb: peak resident set size 503.4 MB exceeds the ceiling of 100 MB (region_in_returned_record_released.max_rss_mb)
❌❌ bees_regions_open_addition/region_in_returned_record_released .sout differs from .scout
```

There is no `.ascomp`: today's assembly is the defective codegen, so it is recorded only when the
leak is fixed. The ceiling is host only; the board ignores the marker, so a board run would need a
program-visible counter (a runtime count of `alloc_region` blocks in `heap_used()`, or a builtin such
as live region bytes; compiler work) to check the leak there.

### SD-7: when to move to `../bees_regions_addition`

With the Mac compiler that has the SD-7 fix, both SD-7 trials pass (the in-flight twin on output and
ceiling, the burst on output); only the H9 trial still fails. They should move to the gated
`../bees_regions_addition` together, with their `.scout`, `.wait_for_exit` and the twin's
`.max_rss_mb`, once the fix is in a built compiler on all three hosts and checked there: the Mac
fixed compiler promoted to `binaries/silica-compiler`, `linux_aarch64` on pix and `linux_x86_64` on
nix each passing this suite, and a board run of the in-flight twin printing `300000` / `done` (the
board ignores the ceiling, so there it checks only that release does not break delivery). They stay
here until then: on any host still on 999943 the twin fails on its ceiling, and the gated suite
must stay green. Moving needs their `.ascomp` goldens from each host's fixed compiler, and a
re-check of the gated suite's existing `.ascomp` goldens (a new shape or atom can renumber them;
refresh only where `.sout` matches `.scout`). The burst trial queues up to 100,000 ~4 KB regions,
which the board's heap cannot hold, so on the board it may need a smaller count or a host-only
marker; that is untested.

When a defect is fixed and its trial passes on every host (output and ceiling), add its `.ascomp`
goldens (Mac, then `linux_aarch64` on pix and `linux_x86_64` on nix) and move it, with its
`.scout` and `.max_rss_mb`, to `../bees_regions_addition` (re-check that suite's other `.ascomp` goldens, which a
new shape can renumber), then delete
this directory once it is empty. The SD-22 trial in `../bees_regions_addition` must still pass
after these are fixed: it is the check that the release does not come back as a scope-exit free.
