# supervisors_board_defects_addition

Board-only trials (`INTEGRATE_PENDING`) for defects seen on the ESP32-S3 when a supervisor is driven from a
caller's context. Each trial's golden is the output it prints once its defect is fixed, so a trial here
fails until then and guards the fix afterwards; the suite is not in `targets/ESP32-S3_raw.skip` on purpose.
The shared helper supervisor is `traits/CycleSup.silica` (a copy of the one `stack_budget_board_addition`
uses).

| Trial | Defect |
| --- | --- |
| `supervisor_ref_after_calls` | code generation, fixed 2026-10-09: a `supervisor_ref` bound in `main` by `spawn_registered_supervisor` (or received as a parameter) and used in a `call_supervisor` after ten `call_registered` calls reached the prim as garbage. `call_supervisor` lowers to a nested let (`let %_supervisor_live_count = supervisor_count_children(rt) in record_make(...)`), and a let inside another let's RHS saw only its own tail as its body, so with all ten callee-saved registers bound the liveness fallback reused the register of a binding that was live after the enclosing let (`rt`'s). Every let RHS now keeps the bound callee-saved registers (`_keep_cs`, as case arms do) in all four emitters. The fault the garbage reference raised was itself hidden by `silica_rt_actor_fault_hook`, whose `9f` early-outs landed on `SCHED_LOCK`'s own local label; fixed the same day. |
| `child_shut_down_with_supervisor_board` | runtime, fixed 2026-10-15: board variant of `supervisors_addition/child_shut_down_with_supervisor` (which the board skips: no preemption, and an actor stays on the core that spawned it). Main gets `:area`'s reference with `:get_child`, moves it to core 1 with `migrate_actor` and casts it a 2^16-call spin, so the root supervisor ends while `:area` runs; the supervisor now shuts `:area` down before it is gone (cascading shutdown, Lee 2026-10-15), and the reporter acts on the root supervisor's report (`2 reports before the root supervisor's`, then `done` and `cast_exit(0)`). Was `child_outlives_supervisor_board` (2026-10-12), whose `:area` outlived the supervisor; the board then printed `[silica] root actor exited (no supervisor)` twice (`silica_rt_actor_deliver_exit` returned 1 for a dead supervisor as well as for none); it prints it once now. |
| `worker_faults_beside_reporter_board` | runtime, 2026-10-16: two actors fault (LoadProhibited, the head of an empty list), one on core 0 beside the FailureReporter pinned there and one on core 1; both reports arrive (reason_tag 3), the reporter's `cast_exit(0)` on the second ends `main`'s wait, and nothing hangs (the board app repros `silica_af3_00` / `silica_actor_fault2`). Named to sort after the other sources so that no atom of the suite's shared table is renumbered |

Run: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=supervisors_board_defects_addition` from `trials/`.
