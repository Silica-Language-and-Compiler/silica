# supervisors_addition

## Restart-race trials: run them in a loop

Five trials here cover races between a dying child, its supervisor's restart and the supervisor's
own teardown, fixed in the runtimes on 2026-10-12 (the dying child's wait for its replacement spun
forever; a supervisor's child table was freed while a dying child still read it). A single
`make integrate` passes them most of the time even without the fixes, so after a runtime change
that touches restarts, supervisor teardown or the FailureReporter, also run each one a few hundred
times:

- `phase_e_root_restart_cap_zero_no_drain`
- `transient_worker_restarted_within_limit`
- `phase_d_protocol_lifecycle_queries`
- `working_registry_child_id_taken_across_supervisors`
- `child_shut_down_with_supervisor` (a child still running when its supervisor ends by a
  restart-limit breach is shut down with it; the reporter acts on the root supervisor's report.
  Was `child_outlives_supervisor_rows_released` (2026-10-12, supervision-block reference count),
  rewritten 2026-10-15 when supervisors began shutting their children down)
- `supervisor_child_names_freed_on_end` (2026-10-15: six :terminate_child / :restart_child cycles of
  a ten-worker child supervisor whose workers are still running; their names are free again for
  each restart)

## Cascading shutdown (Lee, 2026-10-15)

A supervisor that ends shuts its children down first, last row first: shutdown 0 ends a child at
once (reason_tag 1), shutdown > 0 is an orderly shutdown with reason (:explicit, :shutdown)
(reason_tag 4; the shutdown time is not enforced), and the children's names are freed before the
supervisor can be restarted. `supervisor_child_names_freed_on_end` and
`supervisor_shutdown_reason_orderly` cover it; goldens of trials whose supervisor ends with children
still running gained those children's reports.

The harness has no repeat option; use [programmer_tools/trial_loop/loop.sh](../../programmer_tools/trial_loop/README.md)
on each built trial, from a scratch directory, for example:

```
bash programmer_tools/trial_loop/loop.sh trials/supervisors_addition/transient_worker_restarted_within_limit 300 8
```

A pass is no hangs and one outcome line. During the 2026-10-12 work, 300 runs of
`transient_worker_restarted_within_limit` on a runtime without the child-table fix gave five faults
in `silica_rt_supervisor_materialize_init_children`.
