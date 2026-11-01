# Actor Scheduler Policy Tutorial: Choosing How Actors Share a Core

This tutorial teaches you how to choose the dispatch-order policy actors sharing one core are run
under, with `set_scheduler_policy(policy: atom) -> :ok | :invalid_policy` (`proc[concurrency]`).

**This primitive is available on the `ESP32-S3_raw` target only.** On hosted targets (`apple_silicon_mac`,
`linux_aarch64`, `linux_x86_64`) actors are OS threads and the operating system schedules them; there is
no Silica-level ready queue to order, so the call is accepted and answers `:ok` for every recognized
name without changing anything (the same pattern as `pin_actor_to_efficiency_core` being a no-op on a
board whose two cores are alike). Everything below describes observable behavior on `ESP32-S3_raw`.

The policy chosen with `set_scheduler_policy` only decides **which ready actor of a core runs next**.
It never changes two things that hold under every policy (spec §15.1.2, §23.1.1):

- **Nothing is ever preempted mid-dispatch.** A running actor keeps the core until its behavior
  function returns or it suspends to wait (an empty mailbox, a `call()` awaiting reply). The scheduler
  only chooses among actors that are already *ready* at that moment.
- **No policy ever moves an actor to a different core.** That is `migrate_actor`'s job, unrelated to
  this tutorial; see [actor_spawning_tutorial.md](./actor_spawning_tutorial.md).

---

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Core Concepts](#core-concepts)
3. [The Four Policies](#the-four-policies)
4. [Examples](#examples)
5. [Policy Comparison](#policy-comparison)
6. [FAQ](#faq)
7. [See Also](#see-also)

---

## Quick Reference

| If you need... | Choose |
| --- | --- |
| A small number of genuinely critical actors that must never wait behind background work, and you can accept that lower-priority actors may starve under sustained load | `:priority_fifo` (the default) |
| Many actors of equal importance, simple to reason about, and no actor should ever wait indefinitely | `:round_robin` |
| Some actors more important than others, but **every** actor — including the least important — must still make guaranteed, bounded-wait progress | `:weighted_fair` |
| The same proportional importance as `:weighted_fair`, but you want to avoid a fixed, guessable turn pattern (e.g. many symmetric workers, or a pattern that could otherwise resonate with another periodic process) | `:lottery` |

If you are not sure yet, start with the default (`:priority_fifo`, since that is what a program gets
if it never calls `set_scheduler_policy`) for a handful of clearly-tiered actors, or switch to
`:round_robin` the moment you notice you don't actually have a priority hierarchy — most programs with
more than two or three peer actors fall into that second case.

---

## Core Concepts

### What a policy orders

Every core keeps its ready actors in three priority tiers — high, normal, low — set per actor with
`set_actor_priority(actor_ref, :high | :normal | :low)` (spec §22.10; default `:normal`). All four
policies read the same three tiers; they differ only in **how** they drain them:

- `:priority_fifo` and `:round_robin` use the tiers only as raw storage (`:round_robin` ignores tier
  order entirely; `:priority_fifo` is strict tier order).
- `:weighted_fair` and `:lottery` turn the same three tiers into **weights** — high 4, normal 2, low 1
  — and use those weights to decide *how much* of the core's turns each tier gets, not just *whether*
  it gets any.

There is no separate weight-setting call: `set_actor_priority` is the only per-actor knob, and its
meaning depends on which policy is active.

### Changing policy at runtime

`set_scheduler_policy` can be called at any time, not only at startup, and it applies to **every**
core identically — there is no way to run one policy on core 0 and a different one on core 1. It takes
effect for future dispatch decisions; actors already queued are not reordered retroactively. An
unrecognized atom returns `:invalid_policy` and leaves the current policy unchanged.

```silica
sequence proc[concurrency]
    result: atom <- set_scheduler_policy(:weighted_fair)
produces
    pure result
end
```

---

## The Four Policies

### `:priority_fifo` (the default)

The head of the highest-priority non-empty queue always runs next; a tier is FIFO internally. As long
as the high tier has ready work, the normal and low tiers never run at all.

**Use when** you have a small, fixed set of actors that are genuinely more important than everything
else on that core — a watchdog, a supervisor's own control-plane actor, a hardware-facing driver actor
— and you are comfortable that lower-tier actors can wait indefinitely while higher-tier work keeps
arriving. This is the only one of the four policies that can starve an actor outright.

### `:round_robin`

One flat FIFO per core; priority tiers are ignored completely. Every ready actor gets a turn in strict
arrival order before any actor gets a second turn.

**Use when** the actors on a core are peers with no real priority relationship — a pool of symmetric
worker actors, for example — and you want the simplest policy to reason about: no actor can starve
another, and there is nothing to configure per actor beyond spawning it.

### `:weighted_fair`

Deficit round robin over the three tiers: each round gives the high tier 4 units of "credit," normal 2,
and low 1; a tier spends its credit one dispatch at a time and forfeits any unused credit once it runs
out of ready actors for that round, so idle tiers never accumulate an unfair backlog. Every tier with
ready work eventually runs, in proportion to its weight.

**Use when** you want the same tiering `:priority_fifo` gives you, but need a guarantee that low- and
normal-priority actors keep making progress even while high-priority actors are constantly busy — for
example, a program that must keep servicing a low-priority telemetry actor even under heavy load on a
primary actor, without silencing it the way `:priority_fifo` would.

### `:lottery`

Same weights as `:weighted_fair` (4 / 2 / 1), but instead of a deterministic deficit-round-robin order,
each ready actor's tier gets tickets proportional to its weight and the number of actors currently
queued in it, and the next dispatch is chosen by a weighted random draw (seeded from the cycle counter).
An actor's *expected* share of the core matches its ticket share, but the exact sequence of any one run
is not reproducible.

**Use when** you want `:weighted_fair`'s proportional guarantees but specifically do **not** want a
fixed, repeating turn pattern — for example, many symmetric high-priority actors where a deterministic
order could line up with some other periodic effect in the system, or where you'd rather have
statistical fairness over time than an exact, predictable sequence. The tradeoff is that a run is
harder to reproduce for debugging: this project's own trials for `:lottery` check only that every ready
actor eventually runs and nothing hangs, not a specific order.

---

## Examples

### Example 1: A watchdog actor that must always preempt background work

```silica
sequence proc[concurrency]
    watchdog: actor_ref <- spawn(0, watchdog_behavior, stack_policy(0, :keep_last_message));
    worker: actor_ref <- spawn(1, worker_behavior, stack_policy(0, :keep_last_message));
    _: atom <- set_actor_priority(watchdog, :high);
    _: atom <- set_actor_priority(worker, :low);
    _: atom <- set_scheduler_policy(:priority_fifo)
produces
    pure 0
end
```

`:priority_fifo` is the default, so this call is only needed if the program changed the policy
earlier and needs to switch back. The watchdog will always run before the worker whenever both are
ready; the worker can be starved if the watchdog is always ready, which is acceptable here because a
watchdog is meant to dominate.

### Example 2: A pool of equal request handlers

```silica
sequence proc[concurrency]
    _: atom <- set_scheduler_policy(:round_robin)
produces
    pure 0
end
```

No `set_actor_priority` calls are needed — `:round_robin` ignores tiers — and every handler spawned
afterward takes an equal turn.

### Example 3: A primary service that must not silence its own telemetry actor

```silica
sequence proc[concurrency]
    service: actor_ref <- spawn(0, service_behavior, stack_policy(0, :keep_last_message));
    telemetry: actor_ref <- spawn(1, telemetry_behavior, stack_policy(0, :keep_last_message));
    _: atom <- set_actor_priority(service, :high);
    _: atom <- set_actor_priority(telemetry, :low);
    _: atom <- set_scheduler_policy(:weighted_fair)
produces
    pure 0
end
```

Under `:priority_fifo` a continuously busy `service` would starve `telemetry` completely; under
`:weighted_fair` `telemetry` is guaranteed 1 turn for every 4 `service` gets.

---

## Policy Comparison

```
Property                  priority_fifo     round_robin       weighted_fair     lottery
────────────────────────────────────────────────────────────────────────────────────────
Uses set_actor_priority   yes (order)       no (ignored)      yes (weight)      yes (weight)
Can starve an actor       yes               no                no                no
Deterministic order       yes               yes               yes               no
Per-dispatch cost         O(1)              O(1)              O(1)              O(1)
Good default for peers    ✗ needs tiers     ✓ simplest        ⚠ works, heavier  ⚠ works, heavier
Good for a strict         ✓ exact fit       ✗ no tiers        ⚠ tiers soften    ⚠ tiers soften
  priority hierarchy                                            into a share      into a share
Guarantees low-priority   ✗ no              ✓ (all equal)     ✓ yes             ✓ (in expectation)
  progress
Reproducible for tests    ✓                 ✓                 ✓                 ✗ (order varies)
```

---

## FAQ

**Q: Can different cores run different policies?**

A: No. `set_scheduler_policy` sets one policy for every core on the chip; there is no per-core
override.

**Q: What happens to actors already queued when the policy changes?**

A: They stay where they are in whichever tier's queue they were already in; the new policy governs
future pushes and pops, not a retroactive reordering of the current queues.

**Q: Does changing scheduler policy affect `migrate_actor` or which core a new actor spawns on?**

A: No. Those are entirely separate: scheduler policy only orders ready actors already on the same
core.

**Q: Is this available on macOS or Linux builds?**

A: The call is accepted everywhere (so a program stays portable) but only has an effect on
`ESP32-S3_raw`; hosted targets always return `:ok` and keep using the OS thread scheduler.

**Q: I want deterministic turn order but proportional to weight — is that `:lottery`?**

A: No, that is `:weighted_fair`. `:lottery` trades the deterministic order away specifically to avoid
a fixed, repeating pattern; use `:weighted_fair` if you need reproducibility.

**Q: Is there a fifth policy planned?**

A: A BEAM-style reduction-counting policy (a bounded number of execution steps per dispatch before a
forced yield) has been discussed as future work, but it is deliberately not implemented: it would
introduce a kind of yield point the language specification does not currently define (§15.1.2 and
§23.1.1 define a yield point only as a behavior returning or the actor suspending to wait), and would
need a specification change defining that new yield-point kind — and how it interacts with the
existing "never preempts between yield points" guarantee — before any implementation is attempted. See
[esp32s3_xtensa_port.md §8.10](../design_documents/ports/esp32s3_xtensa_port.md) for the full note.

---

## See Also

- [actor_spawning_tutorial.md](./actor_spawning_tutorial.md) — choosing a migration strategy and core
  affinity at spawn time (a different axis: which core an actor runs on, not its turn order once there)
- [supervisors_and_failure_reporter_tutorial.md](./supervisors_and_failure_reporter_tutorial.md) —
  supervising the actors you spawn
- [esp32s3_xtensa_port.md §8](../design_documents/ports/esp32s3_xtensa_port.md) — the `ESP32-S3_raw`
  actor runtime this policy governs, including §8.10's policy implementation notes and the deferred
  fifth-policy note
- [silica-specification.md](../design_documents/silica-specification.md) — §15.1.2 (dispatch
  boundaries and scheduler yield points), §22.10 (`set_actor_priority`, `priority_level`), §23.1.1
  (Process Scheduler)
- `trials/scheduler_policy_addition/` — the trials this tutorial's examples are drawn from, including
  the exact expected dispatch order for each policy
