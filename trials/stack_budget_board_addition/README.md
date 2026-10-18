# stack_budget_board_addition

Board-only trials for the ESP32-S3 stack and heap budget (`actor_memory_budget_plan.md` items A, D and F). On the
board `main`'s two stacks are fixed, sized per image by `board/tools/main_stack_bound.py` (a static
walk over the linked image, run by `build_image.sh`), while every actor's and supervisor's two stacks
are chains of heap chunks that start at 2 KB + 512 B on the first dispatch, grow where an emitted
prologue or auxiliary-stack reservation finds its limit crossed, and are released at the dispatch
boundary by the actor's `stack_policy` algorithm (`rt_actors.S`, "Growable stacks";
[esp32s3_xtensa_port.md §8.3](../../compiler/design_documents/ports/esp32s3_xtensa_port.md)). The
hosted targets grow by pages and expect megabytes, so these trials carry no hosted goldens
(`INTEGRATE_PENDING`); their goldens were derived by hand and checked on the board.

| Trial | Shows |
| --- | --- |
| `actor_deep_recursion_grows` | a behaviour recursing 2,000 deep grows its stack to ~140 KB and completes, where item D's 8 KB block failed; `:keep_last_message` gives the chunks back after a shallow message |
| `actor_machine_overflow_ends_actor` | an actor under a lowered reservation (8 KB) grows into a second chunk for a 30-deep message and ends with `(:explicit, :stack_exhausted)` (reason tag 4) when a 100,000-deep one reaches the reservation; a fresh actor still works. The deep message goes through a relay actor, whose call raises `actor_not_found` when the actor ends (spec §16.1.1), so the relay fails too (reason tag 4) |
| `actor_aux_overflow_ends_actor` | an actor whose nested expressions carry slabs on the auxiliary stack past a lowered reservation (4 KB) ends the same way (through a relay, as above); one level of nesting fits the first auxiliary chunk |
| `actor_high_water_within_reserve` | `get_actor_memory_usage` on the board: reserved is the whole heap at the default reservation, committed and retained are the chunks held, high water the most held; a shallow message after a deep one lowers committed, not the mark |
| `stack_release_algorithms` | `:release_on_return`, `:keep_last_message`, `:track_recent_peak` and `:keep_high_water` keep what spec §15.1.2.2 says after a deep message and the shallow ones that follow |
| `stack_release_when_idle` | `:release_when_idle` holds the deep message's chunks and gives them all back once no message has arrived for a second |
| `supervisor_wide_init_fits` | a root supervisor declaring eight children in one `init` literal (a ~4.8 KB frame on the supervisor's own stack) starts them all, and the first answers |
| `supervisor_ten_child_init` | the same with ten children (a ~5.7 KB `init` frame, a chunk of its own size) |
| `thousand_actors_at_rest` | a thousand `:release_on_return` actors, each dispatched once, hold no stack afterwards and leave the heap with room (§13) |
| `main_recursion_keeps_default` | a `main` that recurses is unbounded for the walk and keeps the documented default (128 KB); 1,500 nested frames run in `main` |
| `main_call_chain_is_bounded` | a `main` whose work is a chain of helpers is bounded exactly; the chain runs on the per-image stack |
| `supervisor_end_frees_child_table` | item A: a ten-worker supervisor ended and restarted ten times through its root (`:terminate_child` / `:restart_child`, each worker ended by a division fault on a scalar cast; main waits for the ten worker reports through the FailureReporter's tally, since spec §16.1.1 makes a call into a worker that faults raise `actor_not_found`) frees its child-table rows, the caller's scope frees its four `call_supervisor` reply records and the runtime frees the restarted init's child-spec list: `heap_used()` grows 4,920 B over the ten cycles (was 19,440 with the rows freed alone, 29,760 with them kept); the golden asserts under 10,000 |
| `failure_reports_free_heap` | a FailureReporter that keeps nothing gives each report string back once `handle_report` returns: over the 20th to the 120th of 120 root-worker division faults the heap grows by less than 20,000 bytes (measured 2026-10-12: 37,600 before the fix, 12,800 after) |
| `string_message_behaviour_frees_heap` | a behaviour whose first parameter is a string builds its `(:no_reply, state)` result in the reply buffer: a counter that casts itself a string message 1,100 times leaves the heap where it was between messages 100 and 1,100 (measured 2026-10-12: 96,000 bytes before the fix, 0 after; golden derived by hand) |
| `tuple_call_result_frees_heap` | a tuple returned by a call inside an actor goes to the caller's result buffer: a counter that calls a tuple-returning helper once per message and casts itself 1,100 messages leaves the heap where it was between messages 100 and 1,100 (Mac before the fix: 16,000 bytes; golden derived by hand) |
| `record_call_result_frees_heap` | the same with a record-returning helper (Mac before the fix: 32,000 bytes) |
| `tuple_return_shapes_free_heap` | the same with a sequence producing a tuple, `p <- f(); p`, and a case whose arm is a tail call (Mac before the fix: 96,000 bytes) |
| `tuple_state_behaviour_frees_heap` | an int64-message behaviour with a (int64, int64) state gives its result and state tuples back each message (Mac before the fix: 32,000 bytes) |
| `case_tuple_literal_arm_frees_heap` | a behaviour whose body is a case with bare tuple-literal arms builds its result in the reply buffer (Mac before the fix: 16,000 bytes) |
| `init_failure_frees_acb` | a root supervisor whose `init` fails gives back what the runtime built for it: `heap_used()` after 25 failed inits equals the heap after 5 (Fable's lki repro, 2026-10-12: equal after the fix; before it the heap grew about 200 bytes per failed init); golden derived by hand |
| `actor_heap_exhausted_on_core1_aborts` | a runtime abort raised by an actor on core 1 (heap exhausted by a string doubled 40 times) ends the whole program with the abort line and status 71 while `main` keeps core 0 busy writing 100,000 empty lines (blank lines are not compared, so how many were written does not matter); the golden is in the folded form `[silica] abort: heap exhausted at <PTR>`, which this suite's `compare_scout_multiset.sh` now applies (2026-10-16); golden derived by hand |

Run: `make integrate TRIAL_TARGET=ESP32-S3_raw TRIAL_SUITES=stack_budget_board_addition` from `trials/`.
