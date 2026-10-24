# failure_reason_line_addition

Trials of the `reason:` line of the actor failure report (spec §15.4.13 unwind report format, §15.4.6.4; the
reasons of §15.4.11.2), in a suite of their own so that their atoms do not renumber the assembly goldens of
`actors_addition` or `supervisors_addition`. The line sits directly above `reason_tag` and spells the
`failure_reason` variant as a program spells it, followed, where the runtime knows the cause, by an em dash
(U+2014) and the detail:

| reason_tag | printed reason |
| --- | --- |
| 0 | `:normal` |
| 2 | `:language_error`, with ` — integer division by zero` or ` — no case arm matched` when the failing site recorded its cause; the shared language-error entry (a call to a cast-only actor, a registered name already taken, `kill_abnormal`/`remove_actor` of self) records nothing and prints the variant alone |
| 3 | `:memory_fault` (a CPU exception inside an actor; the ESP32-S3 board only) |
| 4 | `(:explicit, :<atom>)`, the atom's name from the runtime's own copy of the program's atom table (`_silica_rt_atom_names`, emitted into the runtime object once per executable) |
| 5 | `:foreign_fault` (a guarded foreign call that faulted) |
| other | `:unknown` |

Every trial registers a FailureReporter that writes each report to standard error and ends the program with
`cast_exit(0)` after the reports it expects; outputs are compared as multisets (`.scout.multiset`): the reports
are written asynchronously, and the compare script masks `actor_id`, `supervisor_acb` and `agent_type_atom`.

| Trial | What it shows |
| --- | --- |
| `reason_division_by_zero` | a worker divides by its message, 0: `:language_error — integer division by zero`, reason_tag 2 |
| `reason_language_error_no_detail` | a call to a cast-only actor (§16.2.6.4): `:language_error` with no detail, reason_tag 2 |
| `reason_explicit_killed` | `kill_abnormal`: `(:explicit, :killed)`, a runtime atom the program never spells |
| `reason_explicit_self_stop_atoms` | `fail_self(:badarg)`, `stop_self((:explicit, :done))` and `stop_self(:normal)`: `(:explicit, :badarg)`, `(:explicit, :done)` (program atoms) and `:normal` |
| `reason_shutdown_and_killed_children` | `:terminate_child` of the inner supervisor of `ReasonInnerSup.silica`: its shutdown-0 worker prints `(:explicit, :killed)`, its shutdown-50 worker `(:explicit, :shutdown)`, the supervisor itself `:normal` |

A `:memory_fault` report is not reachable from a hosted trial (no host site records tag 3); the board's fault hook
gives it for a CPU exception inside an actor.

Run: `make -C failure_reason_line_addition integrate` (host), or `make integrate TRIAL_SUITES=failure_reason_line_addition`
from `trials/`.
