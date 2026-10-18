# trial_loop

`loop.sh` runs one built host trial many times in parallel, to show a race that a single
`make integrate` run passes most of the time. The trial harness has no way to repeat a trial, so
this script is the method; it was first used on 2026-10-12 for the supervisor restart and
FailureReporter runtime fixes (restart-wait spin, child-table use after free).

```
mkdir -p /tmp/loop && cd /tmp/loop
bash programmer_tools/trial_loop/loop.sh <trial_binary> <runs> <parallel> [marker] [marker_count] [hang_seconds]
```

- `<trial_binary>` is the executable a suite's `make integrate` (or `make`) left in the suite.
- Each run goes through `trials/actors_addition/run_integration_exit_after_marker.py`, as the
  suites run marked trials: `exit` is written to standard input after `marker_count` occurrences of
  `marker` (default `done`, 1, the supervisors_addition convention). A trial that ends by itself
  (cast_exit) ends the run the same way.
- A run still going after `hang_seconds` (default 15) is reported as `HANG`, sampled with
  `sample(1)` into `runs/r<i>/sample.txt`, and killed.
- The summary is the number of hangs, then `count  <failure reports> <exit status>` for each
  distinct outcome. One line and no hangs is a pass.

Example (200 runs, 8 at a time):

```
bash programmer_tools/trial_loop/loop.sh trials/supervisors_addition/phase_e_root_restart_cap_zero_no_drain 200 8
== phase_e_root_restart_cap_zero_no_drain: 200 runs, hangs: 0
 200 2 0
```

It writes `runs/` in the current directory (emptied first), so run it from a scratch directory.
The hang sample uses macOS `sample(1)`; elsewhere a hang is still reported and killed, without a sample.
