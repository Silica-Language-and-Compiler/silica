# timers_addition

Trials of the clocks and timers of spec §22.14 (`monotonic_time`, `current_time`, `send_after`,
`cancel_timer`) and the `timer_ref` type of §4.5.2, in a suite of their own so that their atoms do not
renumber the assembly goldens of `actors_addition`. No trial prints a time (times are not reproducible):
every line is a comparison (`elapsed >= 50ms: true`), an order, or a `cancel_timer` answer, and every
bound is a lower bound with a generous margin, so a loaded machine can only make a timer later, never
earlier, and the deadline order is kept by the service however late the deliveries run. Each trial
registers a FailureReporter first (E2236); the reporter ends the program with status 70 on an abnormal
report, so a failure never passes as a timing miss. Two trials end a worker with `stop_self(:normal)`,
whose normal-exit report and `[silica] root actor exited (no supervisor)` line are part of their goldens,
compared as multisets (`.scout.multiset`).

| Trial | What it shows |
| --- | --- |
| `monotonic_never_decreases` | 2000 consecutive readings in main and 20 readings across an actor's dispatches never decrease (§22.14.1). |
| `current_time_plausible` | the wall clock is between 2026-01-01 and 2100-01-01 (ms since the epoch); a later monotonic reading is not below an earlier one. |
| `send_after_fires_once_not_early` | a 50 ms timer to self delivers once and no earlier than 50 ms on the monotonic clock. |
| `send_after_zero_enqueues_now` | `send_after(0, peer, 1)` followed by `cast(peer, 2)`: the peer sees 1 then 2; cancelling the delay-0 timer afterwards is `:not_found`. |
| `timers_fire_in_deadline_order` | 120 / 40 / 80 ms timers armed in that order deliver 1, 2, 3. |
| `cancel_before_fire` | cancel of a pending timer is `:cancelled`; the message never arrives (checked 300 ms later). |
| `cancel_after_fire` | cancel from the dispatch handling the timer's own message is `:not_found`; the ref lived in the actor's state. |
| `double_cancel` | `:cancelled` then `:not_found`. |
| `cancel_from_other_actor` | the owner sends the `timer_ref` as a message; the other actor's cancel is `:cancelled`; nothing is delivered to the owner. |
| `target_ended_before_fire` | the target stops itself before a 60 ms timer fires: the message is dropped silently, the sender is unaffected, a later cancel is `:not_found`. |
| `auto_cancel_when_target_ends` | a 10 s timer whose target has ended is cancelled automatically: `cancel_timer` answers `:not_found`. |
| `timer_ref_equality_and_storage` | `==` / `!=` on timer refs; a ref kept in actor state and one carried in a message record `{ t: timer_ref, n: int64 }`, both cancelled from elsewhere. |
| `receive_after_pattern` | the receive-after shape (project BEES): a requester waits by ending its dispatch with a timeout armed; round 1 the reply comes first and the timeout is cancelled, round 2 the timeout comes first. |
| `cancelled_timers_release_messages` | 100,000 timers carrying a fresh ~4 KB region each are armed and cancelled at once; peak RSS under 48 MB (`.max_rss_mb`; a leak of the messages would be ~400 MB). |

A `timer_ref` has no literal, so a trial whose state record holds one starts with a delay-0 timer to
an idle actor as the initial field value.

The compile-time rejections (E2237 for a call-only target, E2003 for an `int64` delay, E2001 for an
integer passed to `cancel_timer`, E2005 for a message without `impl ActorMessage {}`) are
`error_enforcement_addition/send_after_call_only_target`, `send_after_delay_not_uint64`,
`cancel_timer_not_timer_ref` and `send_after_message_not_actor_message`.

Run: `make -C timers_addition integrate` (host), or `make integrate TRIAL_SUITES=timers_addition` from `trials/`.
