# Supervisors and the FailureReporter — Programmer's Tutorial

This document explains how to use Silica supervisors, how to implement the
`FailureReporter` trait, and what output you can expect to see at runtime —
both the human-readable `rep` string (including the call stack) and the binary
`dumps` list.

---

## 1. Actors and Links

Every Silica actor runs on its own OS thread with its own dedicated stack and
memory region.  Actors communicate only through messages (`cast` and `call`);
they share no mutable state.

`spawn` creates a standalone actor with no supervision:

```silica
worker: actor_ref <- spawn(initial_state, worker_beh);
```

`spawn_linked` creates an actor **and** atomically establishes a bidirectional
supervision link between the calling actor (the parent) and the new child:

```silica
child: actor_ref <- spawn_linked(initial_state, child_beh, :child_role);
```

The third argument is an **`agent_type` atom** — a static label that identifies
the child's role.  The runtime embeds this atom in every exit notification and
unwind report, so the supervisor can branch its policy without inspecting opaque
state.

When a linked child dies for any reason — a language error, a hardware memory
fault, or an orderly shutdown — the runtime delivers a structured exit
notification to the parent's **supervision ingress**, a dedicated high-priority
channel that is drained before the ordinary mailbox on each scheduling cycle.

---

## 2. The `Supervisor` Trait

A supervisor actor is defined by implementing the `Supervisor` trait.  The
trait requires one callback:

```silica
trait Supervisor {
    fn init(state: ActorState) -> (supervisor_flags, List[child_spec, mem(normal)])
}
```

`init` is called once when the supervisor starts.  It returns:

- **`supervisor_flags`** — the restart strategy and intensity limits.
- A **list of `child_spec` records** — one per declarative child to start.

The runtime spawns each child via `spawn_linked`, appends a row to an internal
heap-allocated child table, and applies the declared restart strategy whenever a
child death arrives on the supervision ingress.

### 2.1 supervisor_flags

```silica
supervisor_flags = {
    strategy:              :one_for_one | :one_for_all | :rest_for_one,
    allowed_restart_count: int,
    restarts_time_frame:   int          -- seconds
}
```

| Strategy | Behaviour on child death |
|----------|--------------------------|
| `:one_for_one` | Restart only the failed child. |
| `:one_for_all` | Restart **all** children when any one fails. |
| `:rest_for_one` | Restart the failed child and every child started **after** it (in declaration order). |

If the number of child restarts within `restarts_time_frame` seconds exceeds
`allowed_restart_count`, the supervisor itself terminates and propagates the
failure to its own supervisor (if any), or to stderr if it is the root.

### 2.2 child_spec

Each `child_spec` carries at minimum:

- `id` — an atom that uniquely names the child within this supervisor.
- `agent_type` — the atom passed as the third argument to `spawn_linked`.
- `start` — a `(initial_state, behavior_fn)` pair used to (re-)spawn the child.
- `restart` — one of `:permanent`, `:temporary`, or `:transient`.
- `shutdown` — `0` kills the child; greater than `0` is an orderly shutdown, with that many milliseconds as the limit (not yet enforced; see 2.4).

| Restart policy | When the runtime restarts the child |
|----------------|-------------------------------------|
| `:permanent`   | Always, regardless of exit reason. |
| `:transient`   | Only on abnormal exits; normal exits are not restarted. |
| `:temporary`   | Never restarted. |

### 2.3 Shutdown

When a supervisor ends, for any reason, it first shuts down its live children, so a subtree never outlives its supervisor.
This holds when its own supervisor terminates it, when it exceeds its restart limit, and when a restart strategy
restarts it. The children are stopped one at a time, last child row first, and the supervisor waits for each. A child
supervisor stops its own children before it ends. Each child's registered names are freed before the parent hears of
the exit and may restart it.

A child with `shutdown: 0` is killed and reports reason tag 1. A child with `shutdown > 0` finishes its current message
and ends with `(:explicit, :shutdown)`, reason tag 4. Each shut-down child produces a failure report like any other death.

### 2.4 Shutdown time limit

The `shutdown` time limit is not enforced yet. Nothing preempts a running message, so a child always finishes its
current message before it stops (as with `kill_abnormal`).

### 2.5 Ad-hoc linked children

A supervisor may also call `spawn_linked` directly in its behavior function
without a `child_spec` row.  The child is still linked and exit notifications
still arrive on the supervision ingress, but **automatic restarts** via the
`Supervisor` machinery do not apply — there is no `child_spec` row to drive
the restart.  Use this for ephemeral tasks whose lifecycle you manage manually.

---

## 3. Two Independent Failure Channels

When a child dies the runtime delivers information on **two entirely independent
channels**.  It is important to understand that these never mix:

| Channel | Receiver | Content | Purpose |
|---------|----------|---------|---------|
| **Supervision ingress** | The child's supervisor | Structured exit notification: actor id, `agent_type`, reason tag | Restart-policy decisions |
| **FailureReporter** | The root `FailureReporter` actor | Human-readable unwind report (`rep`) + binary region snapshots (`dumps`) | Logging and debugging |

The supervisor never sees the unwind report text.  The `FailureReporter` never
makes restart decisions.

---

## 4. The `FailureReporter` Trait

`FailureReporter` is the system-wide delivery point for all unwind reports.
There is **one** root `FailureReporter` actor per system, analogous to OTP's
Logger.

```silica
trait FailureReporter {
    fn region_dump_limit() -> int64
    fn handle_report(dumps: List[(atom, bytes), mem(normal)], rep: string) -> :ok
}
```

### 4.1 `region_dump_limit`

Returns the maximum number of bytes to capture per memory region when an actor
dies.  The runtime calls this **once at startup** (when
`register_failure_reporter` is called) and caches the result for the lifetime
of the process.

- Return `0` to disable binary region snapshots entirely (`dumps` will always
  be an empty list).
- Return a positive integer (e.g. `2048`) to enable capture of up to that many
  bytes from each region the dying actor held.

### 4.2 `handle_report`

Called **once per actor death**, on the `FailureReporter` actor's own OS thread,
after the runtime has composed the textual report and optional region snapshots.

- `rep` — the formatted unwind report string (see §5 below).
- `dumps` — a list of `(atom, bytes)` pairs, one per region the dying actor
  held.  Currently at **milestone (a)**: always an empty list.  Binary region
  bytes will be populated in **milestone (b)**.

`handle_report` decides what to do with the data — write to stderr, append to a
log file, forward to a remote sink, etc.  It must not block indefinitely; a
stuck `FailureReporter` delays subsequent reports but does not affect supervisor
restart logic, which proceeds independently.

### 4.3 Asynchronous delivery

The runtime composes the unwind report **before** the dying actor's stack is
reclaimed, then **enqueues** it to the `FailureReporter` actor the same way an
ordinary `cast` is enqueued.  `handle_report` is therefore **never called
synchronously from the dying actor's teardown path** and never from the
supervisor restart code.  The two paths — restart decision and logging — are
fully decoupled.

If the enqueue fails (OOM or the `FailureReporter` has not been registered
yet), the runtime falls back to writing the report directly to **stderr**.

---

## 5. Implementing a FailureReporter

### 5.1 Minimal implementation (reports to stderr)

```silica
use FailureReporter;

impl MyReporter for FailureReporter;

fn region_dump_limit() -> int64 {
    0
}

fn handle_report(dumps: List[(atom, bytes), mem(normal)], rep: string) -> :ok {
    sequence proc[device_io]
        _: atom <- print_string_stderr(rep);
        _: atom <- println_stderr("")
    produces
        pure :ok
    end
}
```

### 5.2 Bridge behavior function

The runtime delivers the unwind report to the `FailureReporter` actor via
`cast`, passing the raw report string as the message payload.  The actor's
behavior function bridges this transport-level string into the typed
`handle_report` call:

```silica
fn my_fr_beh(transport_report: string, state: int64) -> (:reply, int64, int64) {
    sequence proc[mem(normal)]
        no_dumps: List[(atom, bytes), mem(normal)] <- empty[(atom, bytes), mem(normal)]();
        _: atom <- handle_report(no_dumps, transport_report)
    produces
        pure (:reply, 0, state)
    end
}
```

The `empty` call produces an empty list for the `dumps` parameter (milestone a).
Once milestone (b) is implemented, the runtime will supply non-empty dumps
directly rather than requiring the bridge to construct them.

### 5.3 Registering the FailureReporter

The `FailureReporter` actor **must be started and registered before any other
actor**.  Registration queries `region_dump_limit()` immediately and caches the
value.  The compiler enforces the order
(spec §15.4.13.4): in `main`'s order of execution, `register_failure_reporter`
must run before any `spawn*` call, in `main` or in any function `main` calls.
A start that can run earlier is rejected with **E2236 StartBeforeFailureReporter**.
The one exemption is the reporter's own `spawn`, when it is written as the
argument of `register_failure_reporter` or bound to a name the same function
then registers.

```silica
fn main() -> int64 {
    sequence proc[concurrency, device_io]
        fr:  actor_ref <- spawn(0, my_fr_beh);
        _:   atom      <- register_failure_reporter(fr);

        -- Now start the rest of the system
        sup: actor_ref <- spawn(0, sup_beh);
        _:   boolean   <- cast(sup, 1 impl ActorMessage {});
        _:   int64     <- wait_for_exit()
    produces
        pure 0
    end
}
```

If no `FailureReporter` is registered when an actor dies, the runtime writes the
report to stderr directly.

---

## 6. What `rep` Contains

### 6.1 Current runtime format

The runtime currently produces a report with the following sections:

```
=== Silica Actor Failure ===
actor_id:        0x10508a300
agent_type_atom: 18
reason_tag:      0
supervisor_acb:  0x10508a180
call_stack:
  #0  failer_a
  #1  _actor_thread_main
=== End Silica Actor Failure ===
```

**Fields:**

| Field | Meaning |
|-------|---------|
| `actor_id` | Pointer to the dying actor's control block (ACB) in hex. |
| `agent_type_atom` | Integer representation of the `agent_type` atom declared at `spawn_linked`. |
| `reason_tag` | 0 for a normal exit; non-zero for abnormal termination. |
| `supervisor_acb` | Pointer to the supervisor's ACB, or 0 for unsupervised actors. |
| `call_stack #0` | Symbol name of the behavior function that was active when the actor died, resolved via `dladdr()`. |
| `call_stack #1` | Always `_actor_thread_main` — the runtime dispatch loop. |

### 6.2 Behavior name resolution

Frame `#0` is resolved by calling `dladdr()` on the behavior function pointer
stored in the actor's control block.  This gives the C-level symbol name (e.g.
`failer_a`), which corresponds directly to the Silica function name.  If
symbol resolution fails (the symbol is stripped from the binary), the frame
shows `<unknown behavior>` instead.

### 6.3 Future format (per spec §15.4.6.4)

The full spec format, targeted for a subsequent implementation milestone, adds
`behavior`, `message_seq`, `reason`, `fault_addr`, and full multi-frame
`stack_trace` with source file and line numbers from DWARF debug information:

```
=== Silica Actor Failure ===
actor_id:     42
agent_type:   :counter_worker
behavior:     counter_module@counter_handler/2
message_seq:  17
reason:       memory_fault

stack_trace:  (most recent call first)
  [0]  counter_module@process_value/1
       at src/counter_module.silica:87
  [1]  counter_module@counter_handler/2
       at src/counter_module.silica:42
  [runtime dispatch frame -- omitted]

supervisor:   7 (type: :root_supervisor)
=== End Silica Actor Failure ===
```

---

## 7. What `dumps` Contains

### 7.1 Current state — milestone (a)

`dumps` is always an **empty list** in the current implementation.  Your
`handle_report` will always receive `[]` for this parameter.  You can safely
ignore it or assert its emptiness in tests.

### 7.2 Future state — milestone (b)

Once milestone (b) is implemented, `dumps` will be a list of
`(atom, bytes)` pairs — one entry per memory region the dying actor held at the
time of death:

```
[(region_id_atom, raw_bytes), ...]
```

Each `bytes` value contains up to `region_dump_limit()` bytes captured from
that region, enabling programmatic analysis: pattern matching on magic values,
checksum verification, recovery of structured data, etc.

The same data is available in human-readable form inside `rep` when
`region_dump_limit() > 0`, rendered as a classic hex dump with an ASCII column:

```
region_dumps:
  [0]  region:3  64 bytes captured of 4096 bytes
       0000:  01 02 03 04 05 06 07 08  09 0a 0b 0c 0d 0e 0f 10  |................|
       0010:  ...
```

On AArch64 with MTE, each row includes the memory-tagging granule values as
`[tags: N N N ...]`.

### 7.3 Controlling capture size

`region_dump_limit()` is queried **once** at `register_failure_reporter` time.
There is no per-actor override.  Choose a value that balances diagnostic
usefulness against the memory overhead of keeping report payloads in the
`FailureReporter` actor's mailbox during high-failure bursts.

| Value | Effect |
|-------|--------|
| `0` | Dumps disabled; `dumps` is always `[]`; no hex section in `rep`. |
| `256` | Capture the first 256 bytes of each region. |
| `2048` | Capture up to 2 KiB per region (a reasonable default for debugging). |

---

## 8. Complete Example

The following example demonstrates three children failing under a single
supervisor, with a `FailureReporter` that prints each full report to stderr.
`main` registers the reporter before it spawns the supervisor, as E2236 requires.
This is the `phase_f9_multi_fail_full_report` trial.

```silica
use FailureReporter;

impl F9FullReportFr for FailureReporter;

-- Capture up to 2 KiB of each region for diagnostic reporting.
fn region_dump_limit() -> int64 {
    2048
}

-- Print the full report to stderr.  Dumps are empty until milestone (b).
fn handle_report(dumps: List[(atom, bytes), mem(normal)], rep: string) -> :ok {
    sequence proc[device_io]
        _: atom <- print_string_stderr(rep);
        _: atom <- println_stderr("")
    produces
        pure :ok
    end
}

fn failer_a(msg: int64, state: int64) -> (:reply, int64, int64) {
    (:reply, msg + state, state + msg)
}

fn failer_b(msg: int64, state: int64) -> (:reply, int64, int64) {
    (:reply, msg + state, state + msg)
}

fn failer_c(msg: int64, state: int64) -> (:reply, int64, int64) {
    (:reply, msg + state, state + msg)
}

fn sup_beh(msg: int64, state: int64) -> (:reply, int64, int64) {
    sequence proc[concurrency]
        a: actor_ref <- spawn_linked(0, failer_a, :f9_child_a);
        b: actor_ref <- spawn_linked(0, failer_b, :f9_child_b);
        c: actor_ref <- spawn_linked(0, failer_c, :f9_child_c);

        _:  atom  <- remove_actor(a);
        p1: int64 <- supervision_wait_and_drain_one();
        _:  atom  <- failure_release(p1);

        _:  atom  <- remove_actor(b);
        p2: int64 <- supervision_wait_and_drain_one();
        _:  atom  <- failure_release(p2);

        _:  atom  <- remove_actor(c);
        p3: int64 <- supervision_wait_and_drain_one();
        _:  atom  <- failure_release(p3)
    produces
        pure (:reply, 0, state)
    end
}

-- Bridge: the runtime delivers the report as a cast; forward it to handle_report.
fn fr_beh(transport_report: string, state: int64) -> (:reply, int64, int64) {
    sequence proc[mem(normal)]
        no_dumps: List[(atom, bytes), mem(normal)] <- empty[(atom, bytes), mem(normal)]();
        _: atom <- handle_report(no_dumps, transport_report)
    produces
        pure (:reply, 0, state)
    end
}

fn main() -> int64 {
    sequence proc[concurrency, device_io]
        fr:  actor_ref <- spawn(0, fr_beh);
        _:   atom      <- register_failure_reporter(fr);
        sup: actor_ref <- spawn(0, sup_beh);
        _:   boolean   <- cast(sup, 1 impl ActorMessage {});
        _:   int64     <- wait_for_exit()
    produces
        pure 0
    end
}
```

### 8.1 Expected stderr output

When the three child actors die, three reports arrive at `handle_report` (order
non-deterministic — the children are removed concurrently):

```
=== Silica Actor Failure ===
actor_id:        0x<address>
agent_type_atom: <integer for :f9_child_a>
reason_tag:      0
supervisor_acb:  0x<address>
call_stack:
  #0  failer_a
  #1  _actor_thread_main
=== End Silica Actor Failure ===

=== Silica Actor Failure ===
actor_id:        0x<address>
agent_type_atom: <integer for :f9_child_b>
reason_tag:      0
supervisor_acb:  0x<address>
call_stack:
  #0  failer_b
  #1  _actor_thread_main
=== End Silica Actor Failure ===

=== Silica Actor Failure ===
actor_id:        0x<address>
agent_type_atom: <integer for :f9_child_c>
reason_tag:      0
supervisor_acb:  0x<address>
call_stack:
  #0  failer_c
  #1  _actor_thread_main
=== End Silica Actor Failure ===
```

`reason_tag: 0` indicates a normal exit.  The three reports are separated by a
blank line because `handle_report` calls `println_stderr("")` after each one.

---

## 9. Implementation Status Summary

| Feature | Status |
|---------|--------|
| `FailureReporter` trait wiring (`register_failure_reporter`, cast delivery, stderr fallback) | Implemented |
| `rep` string — header fields (actor_id, agent_type_atom, reason_tag, supervisor_acb) | Implemented |
| `rep` string — call stack (`#0 behavior_name` via `dladdr`, `#1 _actor_thread_main`) | Implemented |
| `rep` string — full spec format (behavior, message_seq, reason atom, source locations) | Pending |
| `region_dump_limit` queried and cached at registration | Implemented |
| `dumps` list — binary bytes per region, milestone (b) | Pending |
| `rep` string — hex dump section in report text | Removed (moved to `dumps` list) |
| MTE tag annotation in dumps | Pending (AArch64 with MTE only) |
