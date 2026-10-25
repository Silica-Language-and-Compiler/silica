# supervisor_exit_reports_addition

Trials of the supervisor report sink (spec §15.4.10.5, §15.4.8.3 `:set_report_sink`), in a suite of their
own so that their atoms do not renumber the assembly goldens of `supervisors_addition` or
`actor_self_stop_addition`. Every trial registers a FailureReporter that prints nothing (so the output holds
only main's and the sinks' lines), spawns a cast-only **sink** whose message is the `exit_report` record
spelled as the spec gives it,

```
{ child: actor_ref, child_id: atom, failure_reason: :normal | :language_error | :memory_fault | (:explicit, atom) | :noproc | :unknown, restarted: boolean, new_child: actor_ref }
```

names it with `call_supervisor(sup, { op: :set_report_sink, sink: s })`, and prints one line per report
(the runtime hands the sink one 64-byte block per report, the record and its `(:explicit, atom)` pair, which
the sink's dispatch frees once the behaviour has returned):
`report: child=<id> restarted=<bool> same_ref=<new_child == child> reason=<failure_reason>`. The sink ends main's
`wait_for_exit()` with `cast_exit(0)` once the expected reports have arrived, so a report that never comes is a
hang (the harness's watchdog), not a silently passing trial. `ReportInnerSup.silica` is the child supervisor of
the two inheritance trials.

| Trial | What it shows |
| --- | --- |
| `report_crash_restarted` | `:set_report_sink` replies `(:ok, :sink_set)`; a `:permanent` worker's division by zero is reported with `restarted` true, a new `new_child` and `failure_reason` `:language_error`. |
| `report_fail_self_temporary_not_restarted` | `fail_self(:boom)` under `:temporary`: `(:explicit, :boom)`, `restarted` false, `new_child == child`, the row removed. |
| `report_stop_self_explicit_transient_restarted` | `stop_self((:explicit, :done))` under `:transient`: the program's own reason carried, restarted. |
| `report_stop_self_normal_transient_not_restarted` | `stop_self(:normal)` under `:transient`: `:normal`, not restarted. |
| `report_order_two_exits` | two workers fail one after the other (the sink makes the second fail on the first's report): reports arrive in ingress order. |
| `report_exits_before_sink_unreported` | an exit handled before the sink is named is not reported; the next one is. |
| `report_sink_inherited_by_child_supervisor` | a child supervisor restarted (`:restart_child`) after the root named its sink inherits it; one started before has none. |
| `report_sink_inherited_by_added_child_supervisor` | a child supervisor added with `:add_child` (a child spec whose `behavior` is `ReportInnerSup@ReportInnerSup_child_start`) after the root named its sink inherits it. |
| `report_hundred_thousand_reports_rss` | 100,000 reports (the sink makes the worker fail again on each); `.max_rss_mb` = 5 MB holds the peak resident set between the leak-free run (2.1 MB) and one that leaks every 64-byte report block (8.6 MB). |
| `report_sink_override_by_child_supervisor` | the inherited sink is replaced by the child supervisor's own `:set_report_sink`; the child's restart-intensity breach is reported to the root's sink with `(:explicit, :restart_intensity_breach)` (multiset: two sinks print independently). |
| `report_dead_sink_dropped` | a sink ended with `kill_abnormal` (by a killer actor; main may not kill) gets nothing, the supervisor is unharmed (multiset: the sink's root note). |
| `report_set_sink_call_only_rejected` | a call-only actor is refused: reply tag `:error`, no sink recorded. |

Compile-time rejection of a sink whose behaviour takes another message type is not implemented (the
cast-convention pass does not follow `call_supervisor` arguments); the runtime refuses call-only sinks.

Run: `make -C supervisor_exit_reports_addition integrate` (host), or `make integrate TRIAL_SUITES=supervisor_exit_reports_addition` from `trials/`.
