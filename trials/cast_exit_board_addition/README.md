# cast_exit_board_addition

Board-only trials for ending the program from an actor on the other core (spec §15.1.2.5,
`actor_memory_budget_plan.md` item K, board half). On the ESP32-S3 `main` runs on core 0 and
`cast_exit` from an actor pinned to core 1 must wake `main`'s parked `wait_for_exit` across cores
(`rt_actors.S` `silica_rt_exit_request_record` under `silica_rt_sched_lock`). The ordinary
`cast_exit_*` trials in `actors_addition` cover the same-core cases on every target.

| Trial | Shows |
| --- | --- |
| `cast_exit_from_other_core` | an actor pinned to core 1 receives a cast, prints, and issues `cast_exit(5)`; the program ends with status 5 |
| `cast_exit_cross_core_call` | an actor pinned to core 1 issues `cast_exit(9)` while serving `main`'s call; the reply still arrives and is printed, then `main`'s wait ends with 9 |

The programs are portable (a host with two or more cores runs them the same way); the suite is
board-only (`INTEGRATE_PENDING`) because no hosted `.ascomp` goldens have been produced for it.
Run: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=cast_exit_board_addition` from `trials/`.
