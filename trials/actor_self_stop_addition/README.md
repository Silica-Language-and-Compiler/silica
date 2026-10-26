# actor_self_stop_addition

Trials of `stop_self` and `fail_self` (spec §15.1.2.3, §15.4.13, §16.1.1), in a suite of their own so that their
atoms do not renumber the assembly goldens of `supervisors_addition` or `actors_addition`. Every trial is one root
supervisor (`impl ... for Supervisor` in the trial file, the stdlib `Supervisor` linked through `.trial_stdlib/`)
with one worker child `:w`, a registered FailureReporter that writes every report to standard error, and `main`
waiting once in `wait_for_exit`. Outputs are compared as multisets (`.scout.multiset`): the reports are written
asynchronously by the reporter.

| Trial | What it shows |
| --- | --- |
| `stop_self_normal_transient_not_restarted` | `stop_self(:normal)` in a cast-only `:transient` child: the dispatch completes, the exit is `:normal` (reason_tag 0), the child is not restarted, its name is free (main's `cast_registered` raises `actor_not_found`, exit 1). |
| `stop_self_normal_permanent_restarted` | the same under `:permanent`: restarted with its initial state; a driver actor syncs with the supervisor through `call_supervisor` and then casts to the replacement. |
| `stop_self_explicit_reply_then_restart` | `stop_self((:explicit, :done))` in a call-only child: the caller still gets the reply, the report shows reason_tag 4, and `:transient` restarts the abnormal exit. |
| `fail_self_call_death_result` | `fail_self(:badarg)` while serving a call from an actor: nothing after it runs, the caller's call raises `actor_not_found` (the caller fails with reason_tag 4), the worker's report shows reason_tag 4 and it is restarted. |
| `fail_self_queued_casts_dropped` | `fail_self(:boom)` in a cast-only child with two casts queued behind the message being served: they are dropped; the replacement answers the next cast with its initial state. |

The compile-time rejections (E2091 outside a behaviour, E2003 for a reason other than `:normal` or `(:explicit, atom)`)
are `error_enforcement_addition/stop_self_in_main`, `fail_self_in_plain_function` and
`stop_self_reason_not_normal_or_explicit`.

Run: `make -C actor_self_stop_addition integrate` (host), or `make integrate TRIAL_SUITES=actor_self_stop_addition` from `trials/`.
