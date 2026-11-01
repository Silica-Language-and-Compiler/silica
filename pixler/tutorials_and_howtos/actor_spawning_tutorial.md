# Actor Spawning Tutorial: Choosing Migration Strategies

This tutorial teaches you how to spawn actors in Silica with appropriate migration strategies. The key insight is that **migration strategy choice depends on runtime behavior patterns, not on actor lifespan**.

Silica actors use a **gen_server-style** execution model: the **runtime** owns the mailbox loop (`recv` is runtime-internal); your **behavior** has type `(Msg, State) -> State`, runs **once per message**, and may perform **`send`**, **`cast`**, and **replies** inside the function body (see [silica-specification.md](../design_documents/silica-specification.md) §15.1.2, §16.2.1). That shapes how you reason about **stack depth** for the strategies below: depth comes from work in **one message turn**, not from “one stack frame per message” in user code.

---

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Core Concepts](#core-concepts)
3. [Decision Flowchart](#decision-flowchart)
4. [Detailed Examples](#detailed-examples)
5. [Performance Implications](#performance-implications)
6. [Common Patterns](#common-patterns)

---

## Quick Reference

Choose migration strategy based on these three questions:

| Question | Answer → Strategy |
|----------|------------------|
| Will this actor migrate **multiple times per second**? | YES → `lazy` |
| Can you tolerate **10-100+ ms pause** during migration? | NO → `lazy` |
| Is stack usage **unpredictable** or **variable**? | YES → `lazy` |
| Migrations are **rare** (< 1/hour)? | YES → `eager_copy` |
| Can tolerate **~12-15 ms pause**? | YES → `eager_copy` |
| Stack usage is **predictable and heavy** (> 50% allocated)? | YES → `eager_copy` |
| Actor **never migrates** between cores? | YES → `static_core` |
| Needs **guaranteed latency** (real-time)? | YES → `static_core` |

---

## Core Concepts

### Actor execution model (gen_server-style)

- **Runtime mailbox loop**: Between messages, the runtime performs `recv()` and then invokes your behavior with the dequeued message and current `State`. User code **never** calls `recv()`.
- **Non-recursive mailbox processing**: You do **not** implement the infinite receive loop yourself (no user-level tail-recursive “receive then recurse” pattern for the mailbox). Unbounded stack growth is **not** expected from processing many messages over time; each handler invocation returns before the next message is received.
- **Sends inside the behavior**: `send`, `cast`, and **request–reply** (reply to the sender using an `actor_ref` or process id carried **in the message type**, when you design it that way) happen **inside** the behavior body, with effects declared on `sequence` blocks as required by the spec.
- **Why this matters here**: Migration and stack-strategy advice below is about **how much stack one message handler uses** (including deep recursion **during** that handler), not about message count.

### Migration Frequency

**How often will this actor move between CPU cores?**

- **High-frequency**: Multiple migrations per second (e.g., request handlers in load-balanced systems)
- **Low-frequency**: Less than once per hour (e.g., background workers, persistent services)
- **Never**: Actor is pinned to a specific core (e.g., real-time compute, dedicated workers)

### Blocking Tolerance

**Can the actor pause while memory is copied?**

- **Cannot block**: Interactive workloads, request handlers, user-facing operations
- **Can block**: Background processing, batch jobs, offline computation
- **Real-time bound**: Must guarantee maximum latency (e.g., vehicle control, financial trading)

### Stack Usage Pattern

**How much of the allocated stack will actually be used?**

- **Light** (< 10%): Short-lived tasks, leaf operations, thin request handlers
- **Moderate** (10-50%): Normal business logic, typical web handlers
- **Heavy** (> 50%): Complex computations, deep recursion **while handling a single message**, memory-intensive work

---

## Decision Flowchart

```
START: Need to spawn an actor

  1. Will this actor migrate?
     NO  → Use static_core (see §3.3)
     YES → Continue to 2

  2. How often will it migrate?
     FREQUENT (> 1/sec)    → Use lazy (see §3.1)
     RARE (< 1/hour)       → Continue to 3
     VARIES/UNPREDICTABLE  → Use lazy

  3. Can you tolerate 10-100+ ms pause?
     NO  → Use lazy (blocking is unacceptable)
     YES → Continue to 4

  4. How much stack will be used?
     UNPREDICTABLE         → Use lazy (avoid upfront cost)
     PREDICTABLE & HEAVY   → Use eager_copy
     PREDICTABLE & LIGHT   → Either works (use lazy as default)

RESULT: Choose strategy and spawn
```

---

## Detailed Examples

### Example 1: Web Request Handler (Frequent Migration, Interactive)

**Characteristics**:
- Fresh actor spawned per request
- Handles 50-100 requests per second (frequent migrations)
- Must respond within 50 ms (interactive)
- Cannot tolerate blocking during request processing
- Typical stack usage: 3-5 MB of 50 MB allocated

**Decision Path**:
1. Will migrate? YES (load balancing across cores)
2. Frequency? HIGH (multiple per second)
3. → Use `migration_strategy:lazy`

**Implementation**:

```silica
spawn_actor(
  proc_def: request_handler,
  initial_stack_size: 50_000_000,      // 50 MB initial
  migration_strategy: lazy,            // Handle frequent migrations without blocking
  numa_aware: true,                    // Prefer local memory
  initial_core: any                    // Scheduler places it
)
```

**Why lazy**:
- Migrations happen frequently (load balancer moves work around)
- Blocking pause would violate interactive latency (> 50 ms limit)
- Stack usage is light (3-5 MB) → page faults (~9 ms) hidden by execution time
- Lazy recovers gracefully: faults distribute across request handling

**Performance**:
- Setup cost: < 1 μs
- Page fault overhead: ~9 ms spread over 50 ms execution (acceptable)
- No pause perceived by client

---

### Example 2: Background Worker (Rare Migration, Can Block)

**Characteristics**:
- Spawned once, runs for hours
- Processes long-running background jobs (email, batch exports, analytics)
- Scheduled to migrate only during load rebalancing (rare)
- Stack usage is predictable: ~30-40 MB out of 50 MB

**Decision Path**:
1. Will migrate? YES (rare load balancing)
2. Frequency? LOW (< 1/hour)
3. Can tolerate pause? YES (batch processing)
4. Stack usage? PREDICTABLE & MODERATE
5. → Use `migration_strategy:eager_copy`

**Implementation**:

```silica
spawn_actor(
  proc_def: background_job,
  initial_stack_size: 50_000_000,
  migration_strategy: eager_copy,      // Copy eagerly when migrating (rare)
  numa_aware: true,
  initial_core: prefer_local            // Start on a NUMA node
)
```

**Why eager_copy**:
- Migrations are rare (once per load rebalancing)
- 12-15 ms pause is acceptable for batch processing (not user-visible)
- Stack usage is predictable (30-40 MB)
- Upfront copy (12.5 ms) is better than lazy recovery (38 ms) distributed over execution
- No page fault overhead during normal operation

**Performance**:
- Setup cost: 12.5 ms (one-time when migration happens)
- Recovery: None (no page faults after copy)
- Between migrations: Fast, clean execution

---

### Example 3: Real-Time Compute (No Migration, Hard Latency)

**Characteristics**:
- Critical real-time workload (e.g., vehicle control, autonomous navigation)
- Cannot afford unpredictable delays
- Must guarantee bounded latency
- Allocated to a specific physical core
- Heavy stack usage (80+ MB of 100 MB allocated)

**Decision Path**:
1. Will migrate? NO (pinned to core)
2. → Use `migration_strategy:static_core`

**Implementation**:

```silica
spawn_actor(
  proc_def: realtime_control_loop,
  initial_stack_size: 100_000_000,     // 100 MB for real-time work
  migration_strategy: static_core,     // Never migrate
  core_affinity: some(physical_core_5) // Pin to specific core
)
```

**Why static_core**:
- No migration = no page faults from memory movement
- Predictable latency (all memory is local to pinned core)
- Can pre-warm TLB and cache
- No interruptions from scheduler relocations

**Performance**:
- Setup cost: Pre-allocate and pin all needed pages
- Latency: Fully predictable, bounded
- No page fault surprises during real-time execution

---

### Example 4: Batch Computation (Single Migration, Predictable)

**Characteristics**:
- Spawned to run a large computation (e.g., machine learning inference, financial modeling)
- Migrated once at startup (if needed) or never
- Execution time: 5-30 seconds
- Stack usage: 200-400 MB (heavy and predictable)
- Can tolerate 100+ ms pause at startup

**Decision Path**:
1. Will migrate? RARELY (once at startup, maybe)
2. Frequency? VERY LOW
3. Can tolerate pause? YES (startup)
4. Stack usage? PREDICTABLE & HEAVY
5. → Use `migration_strategy:eager_copy`

**Implementation**:

```silica
spawn_actor(
  proc_def: batch_inference,
  initial_stack_size: 300_000_000,     // 300 MB for heavy computation
  migration_strategy: eager_copy,      // Copy upfront; then run clean
  numa_aware: true
)
```

**Why eager_copy**:
- Only one migration expected (at startup)
- Heavy stack usage (200+ MB) means lazy recovery would be expensive
- Eager copy (128 ms) is cheaper than lazy (256 ms) for 300 MB stack
- Batch processing can tolerate startup pause
- Clean, predictable execution after copy

**Performance**:
- Setup cost: ~100 ms (one-time at startup)
- Then: Fast, clean execution with no page faults
- Total overhead: 100 ms / 5-30 sec = 0.3-2% (acceptable for batch)

---

### Example 5: Microservice with Unpredictable Behavior

**Characteristics**:
- Spawned to handle varying requests
- Stack usage depends on request complexity (5-50 MB out of 50 MB allocated)
- Migration patterns are unpredictable (scheduler decides)
- Cannot tolerate blocking (API endpoint)

**Decision Path**:
1. Will migrate? PROBABLY (scheduler may move it)
2. Frequency? UNPREDICTABLE
3. Can tolerate pause? NO (API latency)
4. → Use `migration_strategy:lazy` (unpredictable behavior)

**Implementation**:

```silica
spawn_actor(
  proc_def: api_handler,
  initial_stack_size: 50_000_000,
  migration_strategy: lazy,           // Handle unpredictable pattern gracefully
  numa_aware: true
)
```

**Why lazy**:
- Migration pattern is unpredictable (scheduler controls it)
- Cannot block on API requests
- Stack usage varies widely per request
- Lazy gracefully handles all cases: unpredictable migrations, variable usage
- Fault cost is amortized over request processing

---

## Performance Implications

### Lazy Migration (`migration_strategy:lazy`)

**Costs**:
- Page fault overhead: ~10 μs per page accessed (one-time per page, per migration)
- Distributed recovery: Faults happen as pages are accessed

**Benefits**:
- Upfront cost: < 1 μs (minimal setup)
- No pause: Actor starts running immediately
- NUMA-aware: Pages migrate to execution core on access

**When it's best**:
- Frequent migrations (> 1/sec)
- Cannot tolerate blocking (interactive workloads)
- Unpredictable stack usage

**Overhead examples**:
- 900 pages accessed: 900 × 10 μs = 9 ms (spread over execution)
- 7,680 pages accessed: 7,680 × 10 μs = 77 ms (spread over hours, if migrated rarely)

---

### Eager Copy (`migration_strategy:eager_copy`)

**Costs**:
- Upfront copy: ~3.125 μs per MB (one-time, blocking)
- For 50 MB: 12.5 ms pause
- For 200 MB: 50 ms pause
- For 512 MB: 128 ms pause

**Benefits**:
- No page faults: Memory is immediately accessible
- No recovery period: After copy, execution is clean
- Predictable: Cost is fixed and happens once

**When it's best**:
- Rare migrations (< 1/hour)
- Can tolerate pause at migration time
- Heavy, predictable stack usage
- Long-running actors (pause amortizes to negligible %)

**Overhead examples**:
- 50 MB actor, 1 migration/hour: 12.5 ms / 3,600 sec = 0.0003%
- 200 MB actor, 1 migration/month: 50 ms / 2,592,000 sec = 0.000002%

---

### Static Core (`migration_strategy:static_core`)

**Costs**:
- Core affinity: One CPU core dedicated to this actor
- Pre-allocation: Stack is pre-allocated and pinned on startup

**Benefits**:
- Zero migration overhead: No faults, no copies
- Predictable latency: All memory is local
- Cache/TLB benefit: Warm caches, predictable instruction timing

**When it's best**:
- Real-time requirements (bounded latency)
- Never migrates (pinned to core)
- High throughput on single core

---

## Common Patterns

### Pattern: Request Handlers (Frequent Migration)

**Symptoms**:
- Spawned multiple times per second
- Interactive latency requirements (< 100 ms)
- Variable stack usage (3-20 MB)
- Load balancer moves them around cores

**Recommended**: `migration_strategy:lazy`

```silica
spawn_request_handler(request) -> ActorRef {
  spawn_actor(
    proc_def: handle_request(request),
    initial_stack_size: 50_000_000,
    migration_strategy: lazy,
    numa_aware: true
  )
}
```

---

### Pattern: Persistent Services (Rare Migration)

**Symptoms**:
- Long uptime (hours to days)
- Migrations only during system maintenance or load rebalancing
- Predictable memory usage
- Can tolerate brief pauses (< 100 ms)

**Recommended**: `migration_strategy:eager_copy`

```silica
spawn_service(config) -> ActorRef {
  spawn_actor(
    proc_def: background_service(config),
    initial_stack_size: 100_000_000,
    migration_strategy: eager_copy,
    numa_aware: true
  )
}
```

---

### Pattern: Real-Time Workers (No Migration)

**Symptoms**:
- Hard latency requirements (< 10 ms response)
- Dedicated to a specific task
- Cannot afford page faults or copying
- CPU pinning is acceptable

**Recommended**: `migration_strategy:static_core`

```silica
spawn_realtime_worker(task) -> ActorRef {
  spawn_actor(
    proc_def: realtime_task(task),
    initial_stack_size: 200_000_000,
    migration_strategy: static_core,
    core_affinity: some(preferred_core),
    numa_aware: true
  )
}
```

---

### Pattern: Batch Processing (Heavy, Predictable)

**Symptoms**:
- Large computation (5-60 seconds)
- Predictable, heavy stack usage (200+ MB)
- Can tolerate pause at startup
- Single or rare migration

**Recommended**: `migration_strategy:eager_copy`

```silica
spawn_batch_job(job_params) -> ActorRef {
  stack_size = estimate_stack_for_job(job_params);
  spawn_actor(
    proc_def: execute_batch(job_params),
    initial_stack_size: stack_size,
    migration_strategy: eager_copy,      // Copy upfront; clean execution
    numa_aware: true
  )
}
```

---

## Migration Strategy Comparison

```
Feature                   lazy              eager_copy        static_core
──────────────────────────────────────────────────────────────────────────
Upfront setup cost        < 1 μs            10-300 ms         Varies
Blocking pause            None              10-300 ms         None
Recovery period           Yes (~10 ms)      No                N/A
Suitable for frequent     ✓ Excellent       ✗ Not suitable    ✗ Not suitable
migrations
Suitable for rare         ✓ Acceptable      ✓ Better          ✗ Not suitable
migrations
Suitable for no           ✗ Not suitable    ✗ Not suitable    ✓ Excellent
migrations
Heavy stack usage         ⚠️ More faults    ✓ Efficient       ✓ Local memory
(200+ MB)
Light stack usage         ✓ Efficient       ⚠️ Wasteful copy  ✓ Overhead
(< 20 MB)
Interactive latency       ✓ Best            ✗ Problematic     ✓ Predictable
Unpredictable use         ✓ Handles well    ✗ Inefficient     ✗ Not suitable
Real-time bound           ⚠️ Unpredictable  ⚠️ Known cost     ✓ Predictable
Simplicity               ✓ Default          ✓ Explicit pause  ⚠️ Core affinity
```

---

## Checklist: Before Spawning an Actor

- [ ] **Identify migration pattern**: Will this actor move? How often?
- [ ] **Know blocking tolerance**: Can it pause? For how long?
- [ ] **Estimate stack usage**: How much memory will it actually use?
- [ ] **Choose initial size**: Start with reasonable default (50 MB), adjust based on analysis
- [ ] **Select strategy**: Use decision flowchart to choose lazy/eager_copy/static_core
- [ ] **Test & measure**: Run actual workload; measure page fault rates and latency
- [ ] **Tune if needed**: Adjust initial_stack_size or migration_strategy based on profiling

---

## FAQ

**Q: Do I implement the mailbox loop or call `recv()` in my behavior?**

A: No. The **runtime** receives messages and calls your behavior `(Msg, State) -> State` once per message. `recv()` is not user-callable. You may use `send`, `cast`, and replies from inside the behavior when your `sequence` blocks declare the right effects (see the specification §15.1.2).

**Q: Should I always use lazy migration?**

A: No. Lazy is a good default for high-frequency migrations and interactive workloads, but eager_copy is better for rare migrations with heavy, predictable stack usage. And static_core is essential for real-time work.

**Q: How do I know if my stack usage is "predictable"?**

A: Run your actor code and measure the maximum stack depth it reaches. If it's roughly the same across all inputs, it's predictable. If it varies wildly, treat it as unpredictable and use lazy.

**Q: What if I'm wrong about migration frequency?**

A: Choose conservatively. If unsure, use lazy (it handles all cases well, with modest overhead). You can always profile later and switch to eager_copy if profiling shows migrations are actually rare.

**Q: Can I change migration strategy at runtime?**

A: No. Choose it when spawning. If you need to change it, spawn a new actor with the correct strategy.

**Q: What about actors that migrate a lot but use heavy stacks?**

A: Use lazy. Frequent migrations mean you cannot afford eager_copy pauses. Lazy will incur page fault overhead (~10 μs per page), but that's better than multi-millisecond pauses on every migration.

---

## See Also

- [actor_growable_stack_design.md](../design_documents/actor_growable_stack_design.md) — Growable per-actor stack, runtime actor loop (§5.2)
- [silica-specification.md](../design_documents/silica-specification.md) — §15 Actor model semantics, §16 Message passing, §22.4 Actor operations
- [silica-specification-additional.md](../design_documents/silica-specification-additional.md) — §4 Actor execution (gen_server pattern) (compiler/tooling contract)
- Performance profiling guide (coming soon)
