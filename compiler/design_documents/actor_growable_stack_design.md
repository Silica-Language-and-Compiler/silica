# Silica Actor Design: Growable Stack Architecture with Lazy Migration

**Version**: 1.0
**Date**: April 2, 2026
**Status**: Design specification. The hosted stack mechanism (§2, §4.1, §4.2, §4.4, §7) was implemented 2026-09-17/18; lazy page migration (§4.3, §5.3) is not (see Implementation status below)

---

## Executive Summary

> **Decisions of 2026-09-17.** The sizing and policy in this document were settled against the language contract in [silica-specification.md](silica-specification.md) §15.1.2.2, which is the authority; where this document and that section differ, the specification wins. The settled points, each of which §15.1.2.2 states: one contiguous reservation per actor, defaulting to the machine's memory plus swap and lowerable per spawn, in place of the earlier 1 GB figure and in place of the segmented stacks the roadmap once proposed; nothing committed at spawn; growth in chunks that double from one platform page to 1 MB and then stay at 1 MB; release at the message boundary under one of five named algorithms chosen at spawn, where the stack policy is a required argument of every spawn form; no per-actor maximum and no runtime cap, so memory exhaustion is the host's affair; the platform's page size rather than a fixed one; `main` is not an actor; NUMA placement and lazy migration only where the platform has NUMA; and a four-field memory report. The implementation plan is [Phase1_TODOs/actor_stack_growth_plan.md](Phase1_TODOs/actor_stack_growth_plan.md). Sections below that still show 4 KB pages, an 8 MB initial mapping, a 1 GB region or a guard page are describing the pre-decision layout and are superseded on those points.

> **Implementation status (2026-10-16).** Checked against `emitter/<target>/terms/prims/prims_actors_stack_asm.silica`
> on `apple_silicon_mac`, `linux_aarch64` and `linux_x86_64`, and against ROADMAP chunk 1.
> **Implemented (hosted, 2026-09-17/18):** the reservation (default the machine's memory plus swap, lowered by
> `stack_policy`), nothing committed at spawn, growth in the fault handler in chunks that double from one platform
> page to 1 MB, the reservation test ahead of the guarded-foreign-call recovery, the five release algorithms, the
> four-field `get_actor_memory_usage`, `(:explicit, :stack_exhausted)` and `(:explicit, :stack_reserve_failed)`, and
> `main` on the platform's ordinary stack (the compiler's own `main` is a small `main` that waits in
> `wait_for_exit`). The control-block fields of §2.2 live at ACB offsets 272 to 391, listed in the module's header;
> the control block is 448 bytes. Where the implementation differs from the text below: the runtime is still one OS
> thread per actor (carriers are ROADMAP chunk 2, hosted part), so the actor thread keeps a 128 KB pthread stack
> for its mailbox loop, switches SP onto the reservation around each behaviour call, and has a 64 KB
> `sigaltstack` (a growth fault happens with SP inside inaccessible memory); a release is an anonymous `MAP_FIXED`
> remap to `PROT_NONE` (on Darwin `madvise(MADV_FREE*)` only re-accounts), not `MADV_FREE`; the lowest page of a
> reservation is never committed, so that reaching it is the end of the reservation; the per-message usage that
> `:keep_last_message` and `:track_recent_peak` need is measured by scanning for the lowest nonzero page of a run
> that is zeroed after every message; `:release_when_idle` is a one-second timed wait in the actor's own mailbox
> loop, since there is no carrier thread to sweep (§4.2.1 says carriers); the implicit heap is a chain of 64 MB
> anonymous blocks with a bounds-checked bump pointer; child-spec children inherit the spawner's policy;
> `stack_policy(reserve, release)` is one word, `(reserve rounded to 16) | algorithm index`, and the release atom
> must be a literal. Trials: `trials/actor_stacks_addition`, `error_enforcement_addition/stack_policy_*`,
> `ffi_addition/app_foreign_call_from_deep_stack`. **Not implemented:** NUMA-node-local commitment and the lazy page
> migration handler of §4.3 and the migration strategies of §5.3 (they apply only to platforms that report NUMA
> nodes; the Mac and the Pi have none), the proactive growth hints of §13.2, and a million idle actors (bounded by the
> host's thread limit until chunk 2 brings carriers). **Not this design:** the ESP32-S3 has no demand paging; its
> stacks are chains of heap chunks, designed and built in [actor_memory_budget_plan.md](actor_memory_budget_plan.md)
> (§5 item F, §11).

This document describes the complete actor memory architecture for Silica, replacing the per-actor heap model with **growable stacks and lazy page migration**. Key design principles:

- **Complete actor isolation**: No concurrent shared mutable data between actors; regions may still **move** across actors by ownership transfer (not aliasing)
- **Growable stacks**: Unbounded allocations within physical RAM
- **Automatic cleanup**: Stack deallocates instantly on actor termination
- **Lazy page migration**: Pages migrate to execution core on access (not upfront)
- **High migration frequency support**: Actors can migrate frequently (< 1 μs latency)
- **NUMA-aware**: Pages automatically migrate to local NUMA node

---

## 1. Architecture Overview

### 1.1 Current Model vs. Proposed Model

| Aspect | Current (Per-Actor Heap) | Proposed (Growable Stack) |
|--------|------------------------|--------------------------|
| **Memory allocation** | malloc/free in per-actor heap | Stack pointer adjustment |
| **Actor isolation** | Separate heaps carved from app heap | Complete isolation via stack |
| **Region passing** | Copied on spawn (expensive) | Passed directly (no sharing) |
| **Cleanup** | Manual tracking required | Automatic on actor termination |
| **Stack size** | Fixed | Growable on demand |
| **Migration cost** | Medium (context + potential copies) | Minimal (< 1 μs context switch) |
| **Page movement** | Upfront (if copies) | Lazy on access |
| **NUMA efficiency** | Flexible but requires management | Automatic (pages local to core) |

### 1.2 Core Constraint: No Inter-Actor Data Sharing

**Fundamental rule**: Actors never share mutable data.

- Each actor has completely isolated memory (its stack)
- Regions are allocated within an actor's stack
- References (`ref(R, Space, T)`) point into the stack of the actor that currently owns the region (ownership may move to another actor only as a whole-region transfer with its references)
- When an actor terminates, all its memory is deallocated instantly
- Type system enforces this isolation at compile time

**Consequence**: No region copies on spawn, no *concurrent* cross-actor aliasing of region data (ownership moves or stays local), and the type system can track moves so runtime reference counting is not required for isolation.

---

## 2. Memory Architecture

### 2.1 Per-Actor Virtual Address Space

Each actor has a **dedicated virtual address space region**:

```
Actor Virtual Memory Layout (Per Actor):
┌──────────────────────────────────────────┐
│         1 GB Virtual Region              │ (configurable, e.g., 256MB - 1GB)
│      (sparse, unmapped pages)            │
├──────────────────────────────────────────┤
│                                          │
│      [Guard Page]                        │ (4 KB, unmapped)
│      (triggers growth)                   │
│                                          │
├──────────────────────────────────────────┤
│                                          │
│      Actor Stack                         │ (grows upward)
│      (allocated pages)                   │ (8 MB initial, extends on demand)
│                                          │
│      ↑ SP (stack pointer)                │
│                                          │
├──────────────────────────────────────────┤
│                                          │
│    Runtime Actor State                   │ (fixed at base)
│    - Message queue                       │
│    - Behavior function                   │
│    - Current state value                 │
│    - Core affinity                       │
│    - Metadata                            │
│                                          │
└──────────────────────────────────────────┘

Key Points (as decided; spec §15.1.2.2):
- Virtual space: one contiguous reservation per actor, mapped with no access rights, so it costs no memory
  and is not counted against the host's memory commitment. Default size: the machine's physical memory
  plus swap, read once at runtime start, rounded to the platform page, just under the total where the
  host's overcommit heuristic would refuse the exact amount. A spawn may lower it with `stack_policy`.
- Physical pages: none committed at spawn. The first access faults in the first chunk.
- No guard mapping: the committed run is one mapping and the inaccessible remainder is the second, so an
  actor costs two mappings, never three. Growth is detected by the fault address lying inside the
  reservation, which the handler tests before any other meaning of a fault.
- Page size: the platform's (16 KB on Apple silicon and the Raspberry Pi 5, 4 KB on most other Linux
  systems). The diagram's "4 KB", "8 MB initial" and "1 GB" are the pre-decision layout.
- On platforms with NUMA nodes, pages are committed on the node of the core the actor is running on.
```

### 2.2 Actor Metadata Structure

```silica
struct ActorStackMetadata {
    // Virtual memory
    virtual_base: int64,              // Start address of 1 GB virtual region
    current_sp: int64,                // Current stack pointer
    guard_page_addr: int64,           // Address of guard page (growth trigger)
    reserve_bytes: int64,             // Size of the reservation (default: machine memory + swap; lowered by stack_policy)
    committed_bytes: int64,           // Bytes committed now
    retained_bytes: int64,            // What the release algorithm keeps while the actor is idle
    high_water_bytes: int64,          // Most ever committed
    next_chunk_bytes: int64,          // Next growth chunk: one page, doubling to 1 MB, then 1 MB
    release_algorithm: atom,          // One of the named algorithms of spec §15.1.2.2, chosen at spawn

    // Physical page tracking
    allocated_pages: ListPageInfo,    // List of allocated pages with NUMA info
    page_count: int64,                // Number of allocated pages

    // NUMA and migration
    creation_numa_node: int64,        // NUMA node where actor was created
    current_numa_node: int64,         // NUMA node of current execution core
    pages_per_numa: MapInt64ToInt64,  // Count of pages on each NUMA node

    // Actor identity and state
    actor_id: int64,                  // Unique actor identifier
    core_id: int64,                   // Current core assignment
    behavior_fn: FunctionRef,         // Behavior function (Msg, State) -> State
    current_state: Value,             // Current actor state (evolves per message)
    mailbox: MessageQueue,            // Incoming message queue
    priority: int64,                  // Scheduling priority

    // Limits and monitoring
    total_allocations: int64,         // Bytes allocated (for monitoring)
}

struct PageInfo {
    virtual_addr: int64,              // Virtual address in actor's space
    numa_node: int64,                 // Which NUMA node this page is on
    accessed_count: int64,            // For optimization heuristics
}
```

### 2.3 Stack Layout Within Virtual Region

```
Detailed Stack Growth Over Time:

Initial Allocation (at spawn):
┌────────────────────────────────┐
│   Guard Page (unmapped)        │  0xFFFFF000 (example)
├────────────────────────────────┤
│   Stack Page 2 (4 KB)          │  0xFFFFF000 - 0xFFFFC000
│   Stack Page 1 (4 KB)          │  0xFFFFC000 - 0xFFF00000
├────────────────────────────────┤
│   Initial Mapping (8 MB)       │  First 8 MB allocated
├────────────────────────────────┤
│   Unmapped (ready to fault)    │  Pages 3-256 unmapped
├────────────────────────────────┤
│   Runtime State (fixed)        │  0x00000000 - 0x00001000
└────────────────────────────────┘
        (1 GB virtual total)

After Growth (guard page fault):
┌────────────────────────────────┐
│   Guard Page (unmapped)        │  Moved up by 4 KB
├────────────────────────────────┤
│   Stack Page 3 (NEW)           │  Allocated on fault
│   Stack Page 2 (4 KB)          │
│   Stack Page 1 (4 KB)          │
├────────────────────────────────┤
│   Allocated (8.004 MB now)     │
├────────────────────────────────┤
│   Unmapped (ready to fault)    │  Pages 4-256 unmapped
├────────────────────────────────┤
│   Runtime State (fixed)        │
└────────────────────────────────┘

After Migration (execution moves, pages stay):
Same physical pages remain on creation NUMA node until accessed.
On access in new location → page fault → lazy migration to new NUMA node.
```

---

## 3. Region and Reference Model

### 3.1 Region Allocation Within Actor Stack

All regions are allocated within the actor's stack:

```silica
// Example: Actor behavior function
fn process_message(msg: Message, state: ActorState) -> ActorState {
    // Allocate region within this actor's stack
    r: region(R1, normal) <- alloc_region(normal);  // Stack allocation

    // Allocate references within the region
    ref1: ref(R1, normal, int64) <- alloc_ref(r, 42);
    ref2: ref(R1, normal, int64) <- alloc_ref(r, 100);

    // Allocate buffer within the region
    buffer: buf(R1, normal, int64, 1000) <- alloc_buf(r, 1000);

    // Use references and buffers
    value: int64 <- read_ref(ref1);
    write_ref(ref1, value + 1);
    x: int64 <- read_buf(buffer, 10);
    write_buf(buffer, 10, x * 2);

    // Process state and return
    new_state: ActorState <- process(msg, state, value, x);
    new_state
}

// On function return:
// - region goes out of scope
// - all refs and buffers within it become inaccessible
// - stack pointer adjusts back (no explicit cleanup)
```

### 3.2 Region Lifetime Rules (Simplified)

**Phase A (Single Scope) - Fully Implemented**:
- When a sequence returns, any `ref(R, Space, T)` in return type must have `region(R, Space)` in return type
- References cannot outlive their region
- **Now simplified**: Region lifetime = actor lifetime (or scope within actor)

**Cross-Actor Region Passing (moves, not sharing)**:
- Regions **may** be passed between actors as **moves**: the region is transferred together with every reference that points into it (and any other handles tied to that region’s lifetime).
- References into the region that are **not** included in the move cannot survive it; memory for those references is **freed** (they do not remain valid in the sender). Any attempted use of a reference after a move is a **compile-time error**.
- There is still **no concurrent sharing** of a region across actors: after a move, only the receiver owns that region’s stack extent.
- Each actor allocates regions within its own stack; the type system enforces move completeness and non-aliasing at compile time.
- **Phases B (nested scopes) and C (cross-function)** analysis remain in scope: escaping regions, cross-function boundaries, and actor sends are all cases where the compiler must verify which references move and which are dropped.

### 3.3 Memory Region Semantics

```silica
// All of these are stack-allocated within the actor:

// Single reference
ref1: ref(R1, normal, int64) <- alloc_ref(r, 42);

// Buffer
buf1: buf(R1, normal, int64, 100) <- alloc_buf(r, 100);

// Atomic reference
atomic1: ref(R1, atomic, int64) <- alloc_atomic(r, 99);

// All live on the actor's stack
// All become inaccessible when actor terminates
// Lifetime automatically managed with actor lifetime
```

---

## 4. Page Fault Handler & Growth

### 4.1 Page Fault Detection

The runtime installs a page fault handler (signal handler on Linux/macOS) or exception handler (Windows) to catch stack page faults:

```pseudocode
// Architecture: AArch64
// Signal: SIGSEGV (Segmentation Fault)
// Handler: actor_stack_page_fault_handler()

void actor_stack_page_fault_handler(int sig, siginfo_t *info, void *context) {
    void *faulting_addr = info->si_addr;
    int actor_id = get_actor_id_from_context(context);
    int current_core = get_current_cpu();

    ActorStackMetadata *meta = get_actor_metadata(actor_id);

    if (is_guard_page(faulting_addr, meta)) {
        handle_stack_growth(actor_id, faulting_addr, current_core);
    }
    else if (is_mapped_page(faulting_addr) && is_wrong_numa(faulting_addr, current_core)) {
        handle_lazy_migration(actor_id, faulting_addr, current_core);
    }
    else {
        // Unexpected fault - actor has memory corruption
        terminate_actor_with_error(actor_id, MEMORY_ERROR);
    }
}
```

### 4.2 Stack Growth Handler

The handler runs for every synchronous fault. Its first test is whether the faulting address lies inside
the reservation of the actor running on the faulting thread; if it does, the fault is stack growth and
nothing else is considered, in particular not the guarded-foreign-call recovery of §15.4, which is
tested only afterwards. That ordering is a decision: C code inside a guarded call that runs past the
committed stack must grow it, not be reported as a foreign fault.

```pseudocode
void handle_fault(void *fault_addr, int current_core) {
    ActorStackMetadata *meta = current_actor_metadata();          // NULL on the main thread
    if (meta == NULL || !inside(meta->virtual_base, meta->reserve_bytes, fault_addr)) {
        return try_guarded_foreign_fault_or_crash();              // not stack growth
    }

    // Commit the next chunk below the current committed run (the stack grows down).
    int64 chunk = meta->next_chunk_bytes;                         // one page at first
    void *new_low = committed_low(meta) - chunk;
    if (new_low < meta->virtual_base) {                           // end of a LOWERED reservation
        fail_actor(meta->actor_id, EXPLICIT(:stack_exhausted));   // never reached with the default
        return;
    }
    int target_numa = numa_node_of(current_core);                 // platforms without NUMA: 0
    if (!commit(new_low, chunk, target_numa)) {                   // the machine is out of memory
        return;                                                   // host OOM behaviour; no cap of ours
    }
    meta->committed_bytes += chunk;
    if (meta->committed_bytes > meta->high_water_bytes) meta->high_water_bytes = meta->committed_bytes;
    if (chunk < 1 MB) meta->next_chunk_bytes = chunk * 2;         // double up to 1 MB, then 1 MB per fault
    // Resume at the faulting instruction.
}
```

At the message boundary the behavior has returned and the stack is empty, so release needs no inspection:

```pseudocode
void on_message_return(ActorStackMetadata *meta) {
    int64 keep = retained_by(meta->release_algorithm, meta);     // e.g. last chunk, or a high-water average
    release_down_to(meta, keep);                                  // same chunk sizes it grew by; MADV_FREE-style
    meta->next_chunk_bytes = next_chunk_for(keep);
}
void on_idle_grace_expired(ActorStackMetadata *meta) { release_down_to(meta, 0); }
```

#### 4.2.1 Release algorithms

The five algorithms of spec §15.1.2.2, with the policies they descend from and the per-actor state each
needs in the control block. `stack_policy` is a required spawn argument, so every actor names one.

| `release` | retains | lineage | ACB state |
|---|---|---|---|
| `:release_on_return` | nothing | decommit-on-free, as in Windows heaps and musl | none |
| `:keep_last_message` | the last message's usage | trim to the last request's working set | last usage |
| `:track_recent_peak` | maximum over the last 32 messages | sliding-window maximum; the same idea as jemalloc's decay-based purging of dirty pages | a 32-entry ring of per-message usage, 256 bytes |
| `:release_when_idle` | everything while busy, nothing after the idle period (1 s by default, `SILICA_IDLE_RELEASE_MS`; an upper bound, since a per-carrier budget releases the oldest early) | the JVM's periodic uncommit of unused committed memory (JEP 346) and jemalloc's `dirty_decay_ms` | time of the last message; a runtime idle sweep |
| `:keep_high_water` | the high-water mark | conventional thread stacks, and glibc's cache of freed thread stacks | none beyond the high-water mark |

The idle sweep that `:release_when_idle` needs runs on the runtime's carrier threads, not on the actor,
and only touches actors that named that algorithm.

### 4.3 Lazy Page Migration Handler

```pseudocode
void handle_lazy_migration(int actor_id, void *remote_page_addr, int current_core) {
    ActorStackMetadata *meta = get_actor_metadata(actor_id);
    int current_numa = get_numa_node(current_core);
    int old_numa = get_page_numa(remote_page_addr);

    if (old_numa == current_numa) {
        // Page is already local - unexpected fault
        terminate_actor_with_error(actor_id, MEMORY_ERROR);
        return;
    }

    // Get existing page
    void *old_physical_page = get_physical_page(remote_page_addr);

    // Allocate new page on current NUMA node
    void *new_physical_page = allocate_page_on_numa(current_numa);

    if (new_physical_page == NULL) {
        // Out of memory on current NUMA node
        // Option 1: Keep using remote page (cross-NUMA, slower)
        // Option 2: Kill actor
        // Option 3: Suspend actor, try again later
        // For now: use remote page
        return;
    }

    // Copy page contents from old location to new
    copy_page(old_physical_page, new_physical_page);  // 4 KB copy, ~1-5 microseconds

    // Unmap old page, map new page
    unmap_page(remote_page_addr);
    map_virtual_to_physical(meta->virtual_base, remote_page_addr, new_physical_page);

    // Update metadata
    for (int i = 0; i < meta->page_count; i++) {
        if (meta->allocated_pages[i].virtual_addr == remote_page_addr) {
            meta->allocated_pages[i].numa_node = current_numa;
            meta->allocated_pages[i].accessed_count += 1;
            break;
        }
    }
    meta->pages_per_numa[old_numa] -= 1;
    meta->pages_per_numa[current_numa] += 1;

    // Optional: Free old page (or keep for quick rollback)
    free_page_on_numa(old_physical_page, old_numa);

    // Flush TLB for this address (ensure new mapping is used)
    flush_tlb_single(remote_page_addr);

    // Resume execution at faulting instruction
    return;
}
```

### 4.4 Error Handling

There is no stack-overflow error and no message to the actor. Growth is not a failure (spec
§15.1.2.2, §15.4.11.2). The only two failures are:

- **Reservation exhausted**, possible only when a spawn lowered the reservation: the actor fails with
  `failure_reason` `(:explicit, :stack_exhausted)`. Its supervisor, if any, applies its restart policy.
- **Reservation impossible**, possible only when a program has chosen its own reservation sizes and run
  the process out of address space: the spawn fails and the spawning actor fails with
  `(:explicit, :stack_reserve_failed)`.

Running the machine out of memory is not an error the runtime reports: there is no cap, a single actor may
consume everything, and the host's out-of-memory behaviour then decides. `:oom` is deliberately not a
`failure_reason`.

---

## 5. Actor Lifecycle and Migration

### 5.1 Actor Creation (Spawn)

```silica
spawn(initial_state: State, behavior_fn: (Msg, State) -> State,
      [core_affinity: CoreAffinity]) -> actor_ref proc[concurrency]
```

**Execution Steps**:

```pseudocode
actor_ref spawn(initial_state, behavior_fn, core_affinity):
    // Step 1: Create actor ID
    actor_id = generate_unique_actor_id()

    // Step 2: Allocate virtual address space
    virtual_base = reserve_virtual_space(1_GB)  // Sparse allocation

    // Step 3: Allocate initial stack pages (8 MB)
    current_core = choose_core(core_affinity)
    current_numa = get_numa_node(current_core)

    for page = 0 to 2048:  // 2048 * 4KB = 8 MB
        physical_page = allocate_page_on_numa(current_numa)
        map_virtual_to_physical(virtual_base, virtual_base + page * 4KB, physical_page)

    // Step 4: Install guard page
    guard_page_addr = virtual_base + 8_MB
    install_guard_page(guard_page_addr)

    // Step 5: Copy initial state into actor's stack
    // (initial_state is copied, not shared)
    state_copy = copy_value_to_actor_stack(actor_id, initial_state)

    // Step 6: Create actor metadata
    metadata = ActorStackMetadata {
        virtual_base: virtual_base,
        current_sp: virtual_base + 8_MB - sizeof(initial_state),
        guard_page_addr: guard_page_addr,
        stack_limit: 0,  // Default: unlimited, bounded only by machine memory (spec §15.1.2.2)

        actor_id: actor_id,
        core_id: current_core,
        creation_numa_node: current_numa,
        current_numa_node: current_numa,
        behavior_fn: behavior_fn,
        current_state: state_copy,
        mailbox: create_mailbox(),
    }

    // Step 7: Register page fault handler
    register_page_fault_handler_for_actor(actor_id)

    // Step 8: Create actor thread/task
    spawn_actor_thread(actor_id, current_core)

    // Step 9: Return actor reference
    return ActorRef { actor_id: actor_id, core_id: current_core }
```

**Key Points**:
- Initial state is **copied into actor's stack**, not shared
- Virtual space is allocated (sparse; doesn't cost physical memory)
- Initial 8 MB is mapped immediately on creation NUMA node
- Guard page installed at 8 MB boundary
- No region copying (no inter-actor sharing)

### 5.2 Actor Execution Loop

```pseudocode
void actor_execution_loop(int actor_id):
    ActorStackMetadata *meta = get_actor_metadata(actor_id);

    loop:
        // Step 1: Receive next message (blocking)
        message = recv_from_mailbox(meta->mailbox);

        if message == TERMINATE:
            goto cleanup;

        // Step 2: Call behavior function
        // Behavior function runs on actor's stack
        new_state = meta->behavior_fn(message, meta->current_state);

        // Step 3: Update actor state
        meta->current_state = new_state;

        // Step 4: Loop back for next message
        goto loop;

    cleanup:
        // Actor terminating
        deallocate_actor_stack(actor_id);
        unregister_page_fault_handler(actor_id);
        return;
```

**Concurrency Model** (gen_server-style):
- The **runtime** owns the message loop: it **receives** one message (blocking), then calls the **behavior function** once with `(message, current_state)`. The behavior returns the **new state**; the runtime stores it and repeats. The behavior is **not** written as a recursive receive loop; unbounded recursion in user code is unnecessary for mailbox processing.
- **Receiving**: Only the runtime calls `recv()` / `recv_from_mailbox`. User code never calls `recv()`.
- **Sending**: `send`, `cast`, and **replies** to the current sender (using the sender’s `actor_ref` or PID carried **in the message**, when the message type includes it) occur **inside** the behavior body as needed. Effects are declared on `sequence` blocks per the language spec.
- **Stack**: Each behavior invocation runs on the actor’s growable stack and returns before the next message is received, so stack depth accrues per message turn, not from an unbounded user-level receive loop.
- State is single-threaded per actor (no concurrent updates)

### 5.3 Actor Migration

```silica
migrate_actor(actor_ref: actor_ref, target_core: uint64)
    -> :ok | :invalid_target | :actor_not_found | :migration_blocked proc[concurrency]
```

**Execution Steps**:

```pseudocode
atom migrate_actor(actor_ref, target_core):
    // Step 1: Validate target core
    if not is_valid_core(target_core):
        return INVALID_CORE

    int actor_id = actor_ref.actor_id
    ActorStackMetadata *meta = get_actor_metadata(actor_id)
    int target_numa = get_numa_node(target_core)

    // Step 2: Pause message processing (if needed)
    // Option A: Pause on next message boundary
    // Option B: Atomic context switch
    // Recommendation: Atomic context switch (faster)

    // Step 3: Update core assignment
    old_core = meta->core_id
    meta->core_id = target_core
    meta->current_numa_node = target_numa

    // Step 4: Move execution context
    // This is the actual migration (< 1 microsecond)
    move_execution_context_to_core(actor_id, target_core)

    // Step 5: Mark pages for lazy migration
    // Don't copy yet; let page faults trigger migration
    mark_pages_for_migration(actor_id, target_numa)

    // Step 6: Resume execution
    // Actor resumes immediately on new core
    resume_actor(actor_id)

    return SUCCESS
```

**Migration Latency Breakdown**:
- Context switch: < 1 μs
- No immediate page copy
- Pages migrate on access via page faults (~ 10 μs per page)
- Performance recovers as actor accesses pages locally

### 5.3.1 Migration Strategy Comparison: Detailed Trade-offs

We considered three migration strategies. Here is a comprehensive comparison:

#### **Strategy Comparison Table**

| Metric | Option 1: Memory Stays | Option 2: Eager Copy | Option 3: Lazy Migration (Chosen) |
|--------|------------------------|---------------------|-----------------------------------|
| **Execution Context Switch** | < 1 μs | < 1 μs | < 1 μs |
| **Initial Migration Latency** | < 1 μs | 100 μs - 10 ms | < 1 μs |
| **Stack Copy Cost** | $0 | O(stack_size) | $0 upfront |
| **Per-Page Migration Cost** | N/A (never migrate) | 1-5 μs/page (upfront) | 10 μs/page (on access) |
| **First Access After Migration** | 100-200 ns (cross-NUMA) | 5-20 ns (local) | 10 μs (page fault) |
| **Subsequent Accesses** | 100-200 ns (cross-NUMA) | 5-20 ns (local) | 5-20 ns (local) |
| **Memory Bandwidth Usage** | 50 GB/s (cross-NUMA) | 90 GB/s (local) | 90 GB/s (local after migration) |

#### **Latency Profiles by Stack Size**

```
Stack Size: 50 MB (12,800 pages)

Option 1: Memory Stays in Place
  - Migration: < 1 μs (instant)
  - First 1 second: ~500-1000 cross-NUMA accesses @ 100 ns = 50-100 μs overhead
  - Sustained: 100-200 ns per memory access penalty (5-10x slower)
  - Total cost: Permanent 5-10x latency penalty

Option 2: Eager Copy
  - Migration: ~12.8 ms (copy 50 MB @ ~4 GB/s = 12.5 ms)
  - First 1 second: < 1 μs (all local)
  - Sustained: 5-20 ns per memory access (no penalty)
  - Total cost: 12.8 ms upfront, then normal performance
  - BLOCKS: Actor cannot process messages during copy

Option 3: Lazy Page Migration (Chosen)
  - Migration: < 1 μs (instant)
  - First 1 second: ~12,800 page faults @ 10 μs = 128 ms
  - Recovery: Pages gradually migrate, 128 ms to full performance
  - Sustained: 5-20 ns per memory access (no penalty)
  - Total cost: 128 ms recovery, then normal performance
  - ADVANTAGE: Actor continues running during recovery
```

#### **Detailed Cost Analysis**

**Option 1: Memory Stays in Place**

```
Costs:
  - Per-access penalty: 100-200 ns (cross-NUMA latency)
  - Bandwidth penalty: 50 GB/s → 90 GB/s (44% reduction)
  - Throughput impact: 5-10x slower for memory-bound workloads
  - Unpredictable: Varies by NUMA topology

Performance Impact Examples:
  - Sequential memory scan: 5-10x slower
  - Cache misses: More expensive (cross-NUMA)
  - Atomic operations: Higher contention across NUMA

Total Cost (per access):
  = 100 ns overhead + coherency traffic
  ≈ 100-200 ns per memory operation

Cumulative over 1 million accesses:
  = 100-200 ms total slowdown

When Used:
  ✗ Not recommended (permanent penalty)
  ✗ Only if migration is truly one-time
  ✗ Acceptable only for I/O-bound actors
```

**Option 2: Eager Copy (Copy Entire Stack)**

```
Costs:
  - Copy latency: O(stack_size)
    - 50 MB @ 4 GB/s write bandwidth = 12.5 ms
    - 100 MB @ 4 GB/s write bandwidth = 25 ms
    - 512 MB @ 4 GB/s write bandwidth = 128 ms
  - Message blocking: Actor stalls during copy
  - Memory bandwidth consumed: Entire bandwidth during copy
  - Cache eviction: Copying evicts useful cache lines

Blocking Latency:
  - During copy, actor cannot receive/process messages
  - Mailbox queues messages (but actor is stalled)
  - Other actors on source core are delayed (cache conflicts)

Bandwidth Impact:
  - Copy saturates memory bandwidth for 12-128 ms
  - Other actors/cores may experience contention
  - System throughput degraded during copy

Recovery After Copy:
  - Performance: Instant (all pages local)
  - No page faults after copy

Cumulative Cost (50 MB actor):
  = 12.5 ms blocking + 0 ms page faults
  = 12.5 ms total pause (noticeable, ~human-perceivable)

Cumulative Cost (512 MB actor):
  = 128 ms blocking + 0 ms page faults
  = 128 ms total pause (very noticeable, UI stall)

When Used:
  ✓ Good if: migrations are rare (once per hour)
  ✓ Good if: actor has small stack (< 10 MB)
  ✗ Bad if: migrations are frequent (multiple per second)
  ✗ Bad if: actor has large stack (> 100 MB)
  ✗ Bad if: system has strict latency requirements
```

**Option 3: Lazy Page Migration (Chosen)**

```
Costs:
  - Per-page migration latency: ~10 μs (page fault + copy)
  - Pages migrate on-demand as accessed
  - No blocking (actor runs during recovery)
  - Distributed cost over time

Page Fault Overhead:
  - Context switch to handler: ~1 μs
  - Copy page (4 KB): ~1-2 μs (4 KB @ 4 GB/s)
  - TLB flush: ~1 μs
  - Resume execution: ~0.5 μs
  - Total: ~3.5-5 μs per page, reported as ~10 μs with variance

Cross-NUMA Access During Recovery:
  - First access to unmigrated page: 10 μs (page fault)
  - Subsequent accesses to same page: 5-20 ns (local)
  - Mixed workload: Gradually transitions from slow to fast

Recovery Time (by stack size):
  - 50 MB (12,800 pages): 12,800 × 10 μs = 128 ms
    - But: Not all pages accessed in first 128 ms
    - Reality: Pages migrate on-demand, recovery gradual
  - 512 MB (131,000 pages): 131,000 × 10 μs = 1.31 seconds
    - But: Only pages actually accessed are migrated
    - Typical: 50% of stack accessed = 0.65 seconds

Access Pattern Examples:
  - Hot (frequently accessed) pages: Migrate within 1-10 ms
  - Warm (occasionally accessed) pages: Migrate within 10-100 ms
  - Cold (rarely accessed) pages: Never migrate (waste of time)

Actor Behavior During Recovery:
  - Can receive and process messages immediately
  - New allocations happen on current NUMA (already local)
  - No blocking; performance degrades gracefully

Bandwidth Impact:
  - Gradual (not sudden)
  - Only for pages being accessed
  - Background migration, doesn't interfere with computation

Cumulative Cost (50 MB actor, 1 second observation):
  = 128 ms page fault overhead (spread over 1 second)
  = 12.8% of time in page faults
  = 12.8 ms effective slowdown

Cumulative Cost (50 MB actor, 10 second observation):
  = 128 ms page fault overhead (one-time)
  = 1.28% of time in page faults
  = 1.28 ms effective slowdown (amortized)

When Used:
  ✓ Good if: migrations are frequent (many per second)
  ✓ Good if: actor has large stack (> 100 MB)
  ✓ Good if: system has strict latency requirements
  ✓ Good if: want to continue processing during migration
  ✗ Slight downside: page fault overhead (~10 μs per page)
  ✗ Slight downside: recovery is gradual, not instant
```

#### **Comparative Scenarios**

**Scenario 1: Load Balancing (Frequent Migrations)**

Situation: System migrates actors between cores 10 times per second (100 ms between migrations)

```
Option 1: Memory Stays in Place
  - Each access after migration: 100-200 ns penalty
  - Over 100 ms: 10 million accesses @ 150 ns = 1.5 seconds lost
  - Result: 1500% slowdown (system unusable)

Option 2: Eager Copy
  - Each migration: 12.5 ms (50 MB)
  - 10 migrations/sec × 12.5 ms = 125 ms blocking per second
  - Result: 12.5% of time blocked (significant)

Option 3: Lazy Page Migration
  - Each migration: < 1 μs
  - 10 migrations/sec × 1 μs = 10 μs overhead per second
  - Pages migrate on access (overlapped with execution)
  - Result: Imperceptible overhead (0.001% of time)

Winner: Option 3 (lazy migration) is 1000x better
```

**Scenario 2: Rare Migration (Once Per Hour)**

Situation: System migrates actor once, then stable for 1 hour

```
Option 1: Memory Stays in Place
  - Permanent 100-200 ns penalty per access
  - Over 1 hour: 3.6 trillion accesses @ 150 ns = 540,000 seconds lost
  - Result: System loses entire day's performance on one actor

Option 2: Eager Copy
  - One-time: 12.5 ms (50 MB)
  - Cost amortized over 1 hour: negligible (0.0003%)
  - Result: Imperceptible cost

Option 3: Lazy Page Migration
  - One-time: < 1 μs + 128 ms recovery
  - Cost amortized over 1 hour: negligible (0.0036%)
  - Result: Imperceptible cost

Winner: Option 2 or 3 (both negligible)
```

**Scenario 3: NUMA-Sensitive Workload (Matrix Multiplication)**

Situation: Actor performs 1 trillion floating-point operations with 80% memory bus utilization

```
Option 1: Memory Stays in Place
  - Bandwidth: 50 GB/s vs 90 GB/s (44% reduction)
  - Time to complete: 1 trillion ops @ 50 GB/s = ~20 seconds
  - Time if local: 1 trillion ops @ 90 GB/s = ~11 seconds
  - Slowdown: 81% (1.81x slower)

Option 2: Eager Copy
  - Copy overhead: 12.5 ms (one-time)
  - Execution: 11 seconds at full bandwidth
  - Total: 11.0125 seconds
  - Slowdown: 0.11% (imperceptible)

Option 3: Lazy Page Migration
  - Recovery: 128 ms (pages gradually migrate)
  - Execution: 11 seconds (mixed local/remote during recovery)
  - Effective average bandwidth during recovery: 70 GB/s
  - Performance during first 128 ms: ~7% slower
  - Total extra time: ~100 ms
  - Slowdown: 0.9% (minimal)

Winner: Option 2 and 3 (Option 1 is terrible)
```

#### **Break-Even Analysis: Short-Lived Actors**

For short-lived actors, we need to determine when Option 2 (eager copy) becomes better than Option 3 (lazy migration). The break-even depends on **actor lifespan vs. recovery time**.

**Key Insight**:
- Option 2 blocks actor for `copy_time`, then runs at full speed
- Option 3 runs immediately but slowly during recovery period
- Break-even is when: `copy_time` ≈ recovery overhead

**Break-Even Lifespan by Stack Size**

```
Stack Size | Copy Time | Recovery Time | Break-Even Lifespan
-----------|-----------|---------------|--------------------
10 MB      | 2.5 ms    | 25.6 ms       | ~15-20 ms
25 MB      | 6.25 ms   | 64 ms         | ~40-50 ms
50 MB      | 12.5 ms   | 128 ms        | ~80-110 ms
100 MB     | 25 ms     | 256 ms        | ~160-225 ms
512 MB     | 128 ms    | 1,310 ms      | ~800ms-1.1 sec

Formula: Break-even ≈ Copy_Time + (Recovery_Time / 2)
  For 50 MB: 12.5 ms + 64 ms = ~76-110 ms range
```

**Interpretation**:

```
If actor_lifespan < break_even:
  → Option 3 (Lazy) is better
  → Option 2 would block longer than actor lives

If actor_lifespan > break_even:
  → Option 2 (Eager) is better
  → Block upfront, run clean for rest of lifetime

Example for 50 MB stack (break-even ≈ 110 ms):
  - 10 ms actor: Use Option 3 (Option 2 never finishes copy)
  - 50 ms actor: Use Option 3 (barely worth copy)
  - 100 ms actor: Use Option 3 (just under break-even)
  - 150 ms actor: Use Option 2 (well above break-even)
  - 500 ms actor: Use Option 2 (copy is 2.5% overhead)
```

**Detailed Break-Even for 50 MB Stack**:

```
Lifespan | Option 2 Timeline | Option 3 Timeline | Winner | Margin
---------|-------------------|-------------------|--------|--------
5 ms     | [12.5ms copy]     | [~0.4ms faults]   | Opt3   | 12.1ms
         | BLOCKED!          | Actor finishes    |        | (Opt2 blocked)
         |                   |                   |        |

10 ms    | [12.5ms copy]     | [~0.8ms faults]   | Opt3   | 11.7ms
         | BLOCKED!          | + 9.2ms work      |        | (Opt2 blocked)
         |                   |                   |        |

50 ms    | [12.5ms copy]     | [~6.4ms faults]   | Tie    | 6.1ms
         | [37.5ms work]     | + 43.6ms work     |        | (nearly equal)

100 ms   | [12.5ms copy]     | [~12.8ms faults]  | Opt2   | 6.3ms better
         | [87.5ms work]     | + 87.2ms work     |        |

150 ms   | [12.5ms copy]     | [~19.2ms faults]  | Opt2   | 13ms better
         | [137.5ms work]    | + 130.8ms work    |        |

256 ms   | [12.5ms copy]     | [128ms recovery]  | Opt2   | 16ms better
         | [243.5ms work]    | + 128ms work      |        |
         |                   | (all local after) |        |
```

**Rule of Thumb for Choosing Option**:

```
If actor_lifespan < copy_time:
  → MUST use Option 3 (Option 2 blocks entire lifetime)
  → Example: 5 ms actor with 12.5 ms copy = impossible

If actor_lifespan < 2 × copy_time:
  → Prefer Option 3 (copy overhead > 33%, not worth it)
  → Example: 10-25 ms actor with 12.5 ms copy

If actor_lifespan ≈ 2-3 × copy_time:
  → Break-even region (either works)
  → Example: 25-50 ms actor with 12.5 ms copy

If actor_lifespan > 3 × copy_time:
  → Prefer Option 2 (copy overhead < 25%, worth it)
  → Example: 50+ ms actor with 12.5 ms copy
```

**Special Case: Ultra-Short-Lived Actors (< 10 ms)**

```
Example: Web request handler (5 ms average)

Option 2 with 50 MB stack:
  - Copy time: 12.5 ms
  - Lifespan: 5 ms
  - Result: Actor BLOCKED, never gets to run!
  - Verdict: ✗ CATASTROPHIC (worse than useless)

Option 3 with 50 MB stack:
  - Setup: < 1 μs
  - Runs immediately
  - Page faults: ~0.4 ms (only if 1 MB accessed)
  - Total time: 5.4 ms (includes faults)
  - Verdict: ✓ ACCEPTABLE

Lesson: Option 3 MUST be used for short-lived actors
```

**Special Case: Very Long-Lived Actors (> 1 second)**

```
Example: Persistent worker (lifetime: 1 hour)

Option 2 with 50 MB stack:
  - Copy overhead: 12.5 ms / 3,600,000 ms = 0.00035%
  - After copy: Full speed for 3,599,987.5 ms
  - Verdict: ✓ Copy cost is negligible

Option 3 with 50 MB stack:
  - Recovery: 128 ms / 3,600,000 ms = 0.0036%
  - Gradually improves as pages migrate
  - Verdict: ✓ Also negligible

Lesson: For long-lived actors, either works (Option 2 slightly cleaner)
```

#### **Clarification: Stack Operations vs. Data Access**

The previous break-even analysis needs important clarification: **not all memory accesses are equal**, and page faults occur only on first access per page.

**Stack Operations (No Cost)**:
```
// These are just stack pointer adjustments, essentially free:
alloc_region(normal)        // SP adjustment, no data access
alloc_ref(r, value)    // Bump allocate (SP + store)
function_call()             // Push return address (SP + store)
return value                // Pop return address (SP + load)
```

**Data Access (Has Latency Cost)**:
```
// These are actual loads/stores to memory, have latency:
read_ref(reference)         // LDR instruction
write_ref(reference, val)   // STR instruction
write_buf(buffer, idx, val) // STR instruction
process_value(variable)     // LDR instructions inside function
```

**Page Fault Triggering**:
```
// Page faults only happen on FIRST access to unmapped page:
r: region(R, normal) <- alloc_region(normal);  // No fault (just SP)
ref1: ref(R, normal, int64) <- alloc_ref(r, 42);  // First touch of page
read_ref(ref1);  // ~1-10 μs fault (if page not migrated yet)

read_ref(ref1);  // No fault (page already migrated)
read_ref(ref1);  // No fault (page already migrated)
read_ref(ref1);  // No fault (page already migrated)

// Only 1 page fault for all those reads!
```

**Key Point**: The 128 ms recovery time assumes **all 12,800 pages are accessed**, not that there are billions of memory operations. In reality:

```
50 MB stack = 12,800 × 4 KB pages

Scenario A: Actor uses all 50 MB
  - Page faults: 12,800 (one per page)
  - Total fault time: 12,800 × 10 μs = 128 ms
  - Data loads/stores after pages migrated: 5-20 ns each (negligible)

Scenario B: Actor uses only 5 MB (10% of stack)
  - Page faults: 1,280 (one per accessed page)
  - Total fault time: 1,280 × 10 μs = 12.8 ms
  - NOT 128 ms (that was worst-case)

Scenario C: Actor uses 100 MB code but only 2 MB data
  - Pages allocated: 25,600 (100 MB)
  - Pages touched: 512 (2 MB)
  - Page faults: 512
  - Total fault time: 512 × 10 μs = 5.12 ms
```

**Corrected Break-Even Analysis (Pages Actually Accessed)**

The previous break-even table assumed **entire stack accessed**. More realistic:

```
Stack Size | Copy Time | If 100% Used | If 50% Used | If 10% Used
-----------|-----------|--------------|-------------|-------------
10 MB      | 2.5 ms    | 25.6 ms      | 12.8 ms     | 2.56 ms
25 MB      | 6.25 ms   | 64 ms        | 32 ms       | 6.4 ms
50 MB      | 12.5 ms   | 128 ms       | 64 ms       | 12.8 ms
100 MB     | 25 ms     | 256 ms       | 128 ms      | 25.6 ms
512 MB     | 128 ms    | 1,310 ms     | 655 ms      | 131 ms

Break-even lifespan (percentage of pages accessed):
50 MB stack, 50% pages used:
  Copy: 12.5 ms
  Recovery: 64 ms (only 50% of pages)
  Break-even: ~50 ms lifespan (not 110 ms)

50 MB stack, 10% pages used:
  Copy: 12.5 ms
  Recovery: 12.8 ms (only 10% of pages)
  Break-even: ~12-15 ms lifespan (much lower!)
```

**Revised Rule of Thumb**

```
For a given actor with known page usage U (percentage of allocated stack):

Recovery time = (U × Stack_Size / 4KB) × 10 μs
Break-even ≈ Copy_Time + (Recovery_Time / 2)

Example: 50 MB stack, actor uses 15% = 7.5 MB
  Recovery time: (0.15 × 50 MB / 4 KB) × 10 μs = 1,920 × 10 μs ≈ 19.2 ms
  Break-even: 12.5 ms + 9.6 ms ≈ 22 ms lifespan

This means:
  - 10 ms actor: Use Option 3 (below break-even)
  - 30 ms actor: Use Option 2 (above break-even)
  - 20 ms actor: Borderline (either works)
```

**Real Impact: Most Actors Use Less Than Full Stack**

Most real-world actors don't use their entire allocated stack:

```
Example: Web Request Handler (allocated 50 MB stack)
  - Request parsing: ~2 MB
  - Temporary buffers: ~1 MB
  - Result computation: ~500 KB
  - Total actual usage: ~3.5 MB (7% of allocated)

Page faults with lazy migration:
  - Pages to fault: 3.5 MB / 4 KB = 896 pages
  - Total fault time: 896 × 10 μs = 8.96 ms

Comparison:
  - Option 2: 12.5 ms blocking (entire lifetime)
  - Option 3: 9 ms recovery (distributed over request processing)
  - Winner: Tie (both ~9-12 ms overhead)

BUT if request lifespan is only 20 ms:
  - Option 2: Blocked for 12.5 ms, only 7.5 ms to process
  - Option 3: Runs immediately, page faults happen during processing
  - Winner: Option 3 (no blocking)
```

**Key Takeaway**: Break-even lifespans are typically **lower than the table suggests** because:

1. Most actors don't allocate and use massive stacks
2. Page faults only count for accessed pages, not allocated pages
3. If actor is short-lived, likely only touches small fraction of stack
4. This strengthens the case for **Option 3 as default** even more

#### **Hybrid Recommendation Based on Lifespan**

```
Use Option 1 (Memory Stays): NEVER
  - Permanent penalty is unacceptable
  - No use case justifies it

Use Option 2 (Eager Copy):
  - IF: Actor lifespan >> copy time (> 3-5× copy time)
  - AND: Stack is pre-sized (predictable)
  - AND: Actor runs long enough to amortize copy
  - Typical: Persistent workers, batch jobs, servers
  - Example: 100+ ms actor with 10-50 MB stack

Use Option 3 (Lazy Migration):
  - IF: Actor lifespan < 3× copy time
  - OR: Actor lifespan is unpredictable
  - OR: Frequent short-lived actors (request handlers)
  - OR: Stack size is not pre-determined
  - Typical: Interactive workloads, request handlers, dynamic tasks
  - Example: 1-100 ms actors, variable stack usage

Silica Recommendation: Option 3 (Lazy Migration) as DEFAULT
  - Reason: Works for ALL lifespans (short and long)
  - Reason: No blocking (interactive-friendly)
  - Reason: Graceful degradation (pages migrate gradually)
  - Reason: No upfront cost (< 1 μs context switch)
  - Reason: NUMA-aware (pages go to execution core)
  - Trade-off: Page fault overhead (~10 μs per page, one-time)

  Note: Applications can use Option 2 for specific long-lived actors
        if profiling shows it's beneficial (> 3× copy time)
```

#### **Decision-Based Scenario Analysis: Choosing Migration Strategy**

**Important**: Migration strategy choice is based on **migration frequency** and **blocking tolerance**, not actor lifespan. These scenarios demonstrate when to use each strategy.

```
DECISION MATRIX:

Migration Frequency: How often will this actor migrate between cores?
Blocking Tolerance: Can the actor be paused while memory is copied?
Stack Usage: What fraction of allocated stack will actually be used?

┌─────────────────────────┬──────────────────────────────────┐
│ Strategy                │ When to Use                      │
├─────────────────────────┼──────────────────────────────────┤
│ migration_strategy:lazy │ • Frequent migrations (> 1/sec)  │
│                         │ • Cannot tolerate blocking       │
│                         │ • Interactive/real-time work     │
│                         │ • Unpredictable stack usage      │
├─────────────────────────┼──────────────────────────────────┤
│ migration_strategy:     │ • Rare migrations (< 1/hour)     │
│ eager_copy              │ • Can tolerate brief blocking    │
│                         │ • Predictable, heavy stack use   │
│                         │ • Benefits from upfront copy     │
├─────────────────────────┼──────────────────────────────────┤
│ migration_strategy:     │ • Never migrates                 │
│ static_core             │ • Critical latency requirements  │
│                         │ • Dedicated core affinity        │
│                         │ • Long-running with no moves     │
└─────────────────────────┴──────────────────────────────────┘


Scenario 1: High-Frequency Migration - Web Request Handler
  Migration pattern: Frequent rebalancing (multiple migrations per second)
  Blocking tolerance: NO - each request is interactive
  Stack allocation: 50 MB default
  Stack usage: 3-5 MB per request (7-10% of allocated)
  Execution time: 20-50 ms per request

  Using migration_strategy:lazy:
    - Setup: < 1 μs (no upfront cost)
    - Page faults for ~900 pages: 900 × 10 μs ≈ 9 ms
    - Faults distributed during 20-50 ms execution
    - Total overhead: ~18-45% (overlapped with computation)
    - Latency: Acceptable (faults hidden by work)
    - Cost per migration: ~9 ms spread across execution
    - ✓ EXCELLENT CHOICE

  Using migration_strategy:eager_copy:
    - Copy 50 MB: 12.5 ms blocking pause
    - Blocks 12.5 ms out of 20-50 ms execution
    - At 20 ms execution: 62% of request time blocked
    - At 50 ms execution: 25% of request time blocked
    - User perceives latency spike
    - ✗ NOT SUITABLE (unacceptable blocking)

  Decision: Use migration_strategy:lazy
           Migration happens frequently; blocking is unacceptable.
           Lazy migration amortizes fault cost over execution.

Scenario 2: Rare Migration - Persistent Worker Actor
  Migration pattern: Rare migrations (once per hour or less)
  Blocking tolerance: YES - can pause for ~12-15 ms
  Stack allocation: 50 MB
  Stack usage: 30 MB (60% of allocated)
  Uptime: 1 hour between migrations

  Using migration_strategy:lazy:
    - Setup: < 1 μs
    - Page faults for ~3,840 pages: 3,840 × 10 μs ≈ 38.4 ms
    - Recovery spread over 1 hour execution
    - Amortized: 38.4 ms / 3,600,000 ms = 0.001% overhead
    - Latency impact: Negligible
    - ✓ ACCEPTABLE

  Using migration_strategy:eager_copy:
    - Copy 50 MB: 12.5 ms blocking pause (one-time at migration)
    - Actor paused, then executes cleanly
    - Amortized: 12.5 ms / 3,600,000 ms = 0.0003% overhead
    - Latency impact: Negligible (upfront cost, then clean)
    - No recovery period
    - ✓ SLIGHTLY BETTER (less total fault overhead)

  Decision: Either works; migration_strategy:eager_copy preferred.
           Since migrations are rare, upfront 12-15 ms pause is acceptable.
           Avoids page fault handling overhead during normal operation.

Scenario 3: Memory-Intensive Batch Job
  Migration pattern: Rare/single migration at startup
  Blocking tolerance: YES - batch processing, can tolerate 100+ ms pause
  Stack allocation: 512 MB for complex computation
  Stack usage: 200 MB (39% of allocated)
  Execution time: 5 seconds total
  Migrations: Once, at actor start

  Using migration_strategy:lazy:
    - Setup: < 1 μs
    - Page faults for ~25,600 pages: 25,600 × 10 μs ≈ 256 ms
    - Recovery distributed over 5 second job
    - Page faults concentrated during initial setup phase
    - Then computation runs with no additional faults
    - Overhead: 256 ms / 5000 ms = 5.1% (mostly in setup)
    - ✓ ACCEPTABLE

  Using migration_strategy:eager_copy:
    - Copy 512 MB: 128 ms blocking upfront (one-time)
    - Blocks for 128 ms, then 4.872 second clean execution
    - No recovery; no additional faults
    - Overhead: 128 ms / 5000 ms = 2.56%
    - Predictable latency (fixed upfront cost)
    - ✓ BETTER for this workload

  Decision: Use migration_strategy:eager_copy
           Stack usage is predictable and heavy. Upfront copy cost
           (128 ms) is lower than lazy recovery (256 ms). Batch
           processing can tolerate the pause at startup.

Scenario 4: Dynamic Workload (Mixed Migration Frequency)
  Migration pattern: Multiple actor types with different patterns
  Need to choose per-actor based on behavior

  Scenario 4a: Short-burst worker (100 ms tasks, frequent migrations)
    Stack: 50 MB allocated, ~5 MB used
    Migrations: Several per second
    Blocking tolerance: NO
    → Use migration_strategy:lazy
      (Frequent migrations + intolerance of blocking)

  Scenario 4b: Background worker (1 hour uptime, migrations rare)
    Stack: 50 MB allocated, ~40 MB used
    Migrations: Once per 8 hours
    Blocking tolerance: YES
    → Use migration_strategy:eager_copy
      (Rare migrations + predictable usage + acceptable pause)

  Scenario 4c: Real-time compute (pinned to core, never migrates)
    Stack: 100 MB allocated, all used
    Migrations: None (affinity bound to core)
    Blocking tolerance: NO (real-time constraint)
    → Use migration_strategy:static_core
      (No migration; CPU pinning; predictable latency)

  Decision: Choose per-actor based on observable characteristics:
           - Frequency of migrations determines primary choice
           - Blocking tolerance breaks ties
           - Stack usage informs allocation strategy
```

### 5.3.2 Actor Movement: Explicit Core Migration

**Built-in Function**:

```silica
migrate_actor(actor_ref: actor_ref, target_core: uint64)
    -> :ok | :invalid_target | :actor_not_found | :migration_blocked proc[concurrency]
```

**Purpose**: Explicitly move an actor from whatever CPU core it is on to another. `migrate_actor` is the user-facing function for actor migration; every actor stays pinned to its core until the program migrates it or it terminates (spec §15.1.2, Actor Pinning Policy).

**Parameters**:
- `processid`: The actor/process identifier to migrate
- `to`: Target core ID where the actor should execute

**Return**: An atom indicating success or failure
- `SUCCESS`: Actor successfully moved to target core
- `INVALID_TARGET`: Target core does not exist or is unavailable
- `ACTOR_NOT_FOUND`: No actor with the given processid
- `MIGRATION_BLOCKED`: Actor is in a non-migratable state (e.g., executing a critical section)

**Execution Steps**:

```pseudocode
atom migrate_actor(processid, to_core):
    // Step 1: Locate actor
    ActorStackMetadata *meta = get_actor_metadata(processid)
    if meta == null:
        return ACTOR_NOT_FOUND

    // Step 2: Validate target core
    if not is_valid_core(to_core):
        return INVALID_TARGET

    // Step 3: Check if actor is migratable
    if is_actor_blocked_for_migration(meta):
        return MIGRATION_BLOCKED

    // Step 4: Perform migration
    int target_numa = get_numa_node(to_core)

    // Atomically update core assignment
    meta->core_id = to_core
    meta->current_numa_node = target_numa

    // Move execution context (< 1 microsecond)
    move_execution_context_to_core(processid, to_core)

    // Mark pages for lazy migration
    mark_pages_for_migration(processid, target_numa)

    // Resume execution on new core
    resume_actor(processid)

    return SUCCESS
```

**Usage Examples**:

```silica
// Migrate the actor to core 4
result: atom <- migrate_actor(my_actor_ref, 4);
case result of {
    SUCCESS ->
        // Actor is now executing on core 4
        print("Actor moved successfully");
    INVALID_TARGET ->
        // Core 4 doesn't exist or is unavailable
        print("Target core unavailable");
    _ ->
        print("Migration failed")
}
```

**Interaction with Migration Strategy**:

`migrate_actor` respects the actor's migration strategy (set at spawn time):

| Migration Strategy | Behavior |
|-------------------|----------|
| `lazy` | Migration completes immediately (< 1 μs), pages migrate on access (~10 μs per page) |
| `eager_copy` | Migration blocks for stack copy (~10-100 ms depending on size), then executes cleanly |
| `static_core` | `migrate_actor` fails with an error if the target core differs from the pinned core |

**Performance Characteristics**:

```
Latency Breakdown (lazy migration):
├─ Validation: ~1 μs
├─ Core assignment update: ~0.1 μs
├─ Execution context switch: < 1 μs
├─ Page marking: ~0.1 μs
└─ Total: < 1.2 μs

Recovery period (pages migrate on access):
├─ First page access: +10 μs (page fault + migrate)
├─ Subsequent pages: +10 μs each
└─ Total recovery: O(pages_accessed)

Latency Breakdown (eager_copy migration):
├─ Validation: ~1 μs
├─ Execution context switch: < 1 μs
├─ Stack copy (blocking): 10-100 ms (depends on stack size)
│  └─ For 50 MB: ~12.5 ms
│  └─ For 200 MB: ~50 ms
│  └─ For 512 MB: ~128 ms
└─ Total: ~10-100 ms (blocks actor execution)
```

**Atomicity and Thread Safety**:

`migrate_actor` is atomic with respect to:
- The actor's execution context (cannot be interrupted mid-migration)
- Core assignment updates (visible immediately to all observers)
- Page marking (all pages marked together)

However, the actor's messages may queue during migration. The actor will process them after resuming on the target core.

**Failure Modes**:

```silica
// Actor terminated before move completes
if actor_terminated(processid):
    return ACTOR_NOT_FOUND

// Another thread/actor moves the same actor
if concurrent_move_detected(processid):
    return MIGRATION_BLOCKED  // Retry

// Target core goes offline during migration
if target_core_offline(to_core):
    return INVALID_TARGET
```

**Restrictions**:

- Cannot move an actor to a non-existent core
- Cannot move an actor pinned to a different core (static_core strategy)
- Cannot move an actor that is terminated
- Cannot move an actor to the core it's already on (optimization: no-op)

### 5.4 Actor Termination

```pseudocode
void terminate_actor(int actor_id):
    ActorStackMetadata *meta = get_actor_metadata(actor_id);

    // Step 1: Wait for current message to complete
    wait_for_message_processing(actor_id);

    // Step 2: Prevent new messages
    close_mailbox(meta->mailbox);

    // Step 3: Free all allocated pages
    for each page in meta->allocated_pages:
        unmap_page(page.virtual_addr)
        free_page(page.physical_page, page.numa_node)

    // Step 4: Release virtual address space
    release_virtual_space(meta->virtual_base, 1_GB)

    // Step 5: Unregister page fault handler
    unregister_page_fault_handler(actor_id)

    // Step 6: Free metadata
    free(meta)

    // Step 7: Remove from actor registry
    unregister_actor(actor_id)
```

**Cleanup Latency**: O(1) for virtual space; O(num_pages) for physical pages
- Deallocating 128 pages (512 MB): ~1-5 milliseconds
- Instant removal from scheduler

---

## 6. Compiler Integration

### 6.1 Type System Changes

**Memory region types remain unchanged**:
```silica
region(R, Space)        // Stack-allocated region
ref(R, Space, T)        // Reference within stack
buf(R, Space, T, N)     // Buffer within stack
ref(R, atomic, T) // Atomic-capable reference within stack (atomic memory space)
```

**Constraint additions**:
```silica
// Compile-time enforcement:
// 1. Region moves across actors include every ref/buf/etc. into that region, or drop those values (free storage for refs not moved)
// 2. Regions allocated within actor stack; moves transfer ownership of the extent
// 3. No dangling refs: refs don't outlive their region; cross-actor only via whole-region move; use after move is a compile-time error
// 4. No shared mutable state across actors (moves transfer ownership, not aliases)

// Type checker enhancement:
// Add "ActorBoundary" to type judgments
// Model region + reference bundles for sends; Phase B/C for escapes and cross-function moves
```

### 6.2 Code Generation Changes

**Region allocation becomes stack allocation**:

```silica
// Before (heap):
fn emit_alloc_region(dest: string) -> string {
    "    MOV X0, #4112\n" +      // Size
    "    BL _malloc\n" +         // Allocate on heap
    "    ADD X4, X0, #16\n" +    // Setup bump pointer
    // ... initialize region ...
}

// After (growable stack):
fn emit_alloc_region(dest: string) -> string {
    "    MOV X0, SP\n" +         // Current stack pointer
    "    SUB SP, SP, #4112\n" +  // Reserve space on stack
    "    ADD X4, SP, #16\n" +    // Setup bump pointer
    // ... initialize region ...
    // No malloc/free
}
```

**Region growth checks**:
```silica
// Emit guards before large allocations
fn emit_alloc_ref(dest: string) -> string {
    // Check if allocation would hit guard page
    "    LDR X3, [X1]\n" +       // Load bump pointer
    "    ADD X5, X3, #8\n" +     // New bump position
    "    CMP X5, [guard_page]\n" + // Compare to guard page
    "    B.HI _stack_growth\n" + // If exceeds, trigger growth
    // ... normal allocation ...
}
```

### 6.3 Compiler Optimizations

**Stack growth hints** (optional):
```silica
// Compiler can provide hints for large allocations
fn process_large_message(msg: LargeMessage, state: State) -> State {
    // If compiler predicts ~10 MB allocation:
    // hint_stack_usage(10_MB);  // Optional, for runtime optimization

    buffer: buf(R, normal, int64, 1_000_000) <- alloc_buf(r, 1_000_000);
    // ... use buffer ...
}
```

**Tail recursion optimization**:
```silica
// Recursion that grows stack can be optimized with TCO
fn process_list(items: ListItem, acc: int64) -> int64 {
    case items.is_nil of {
        true -> acc;
        false -> process_list(items.tail, acc + items.head)  // TCO candidate
    }
}
```

---

## 7. Memory Limits and Configuration

### 7.1 Stack Size Limits

There are none. Neither a per-actor maximum nor a runtime-wide cap exists, and a stack grows until the
machine, including its swap, is exhausted (spec §15.1.2.2). What a spawn can set is the reservation,
which bounds address space rather than memory, and the release algorithm:

```silica
// Default reservation = machine memory + swap; the release algorithm is always named
actor1: actor_ref <- spawn(state1, behavior1, stack_policy(0, :keep_high_water));

// A program spawning millions of actors lowers the reservation so they fit in address space
actor2: actor_ref <- spawn(state2, behavior2, stack_policy(33554432, :release_on_return), core_id(3));
```

**Runtime constants** (the platform page is read at start; nothing else is configurable):

```
- Committed at spawn: 0
- First chunk: one platform page (16 KB on Apple silicon and Raspberry Pi 5, 4 KB on most other Linux)
- Growth: double per fault up to 1 MB, then 1 MB per fault
- Default reservation: physical memory + swap, page-rounded, just under the total where the host refuses the exact amount
- Mappings per actor: 2 (committed run, inaccessible remainder); no guard mapping
```

### 7.2 Memory Monitoring

```
get_actor_memory_usage(ref: actor_ref) -> { reserved: int64, committed: int64, retained: int64, high_water: int64 }   proc[concurrency]
```

All four in bytes (spec §15.1.2.2, §22.4). `get_actor_page_locations`, the NUMA-node breakdown, applies
only on platforms with NUMA nodes.

### 7.3 Out-of-Memory Handling

See §4.4: exhausting a lowered reservation fails the actor with `(:explicit, :stack_exhausted)`; exhausting
the machine is the host's affair and is reported by no actor.

## 8. Performance Characteristics

### 8.0 Terminology Clarification

Throughout this section, when we discuss "accesses" and page faults, it's important to understand the distinction:

**Stack Operations** (No Direct Cost):
- `alloc_region()` - just SP adjustment
- Function calls/returns - push/pop return address
- Variable allocation - SP adjustment
- These are essentially free (single register operation)

**Data Access** (Has Latency Cost):
- `read_ref()` - LDR instruction (5-20 ns local, 100-200 ns cross-NUMA)
- `write_ref()` - STR instruction (same latency as read)
- Reading/writing variables - LDR/STR instructions
- Dereferencing pointers - LDR/STR instructions

**Page Faults** (One Per 4 KB Page):
- Occur only on **first access to an unmapped page**
- Cost: ~10 μs per page (migrate page + TLB flush)
- NOT per instruction - only one per 4 KB of memory touched
- Example: Reading 100 values from same page = 1 page fault, then 100 fast reads

**Key Insight**: Recovery time of "128 ms for 50 MB stack" assumes:
- All 12,800 pages are accessed (one fault per page)
- NOT 128 million accesses
- If actor only uses 5 MB (10% of stack), recovery is ~12.8 ms
- If actor only uses 500 KB (1% of stack), recovery is ~1.28 ms

This distinction is critical for understanding actual break-even points and realistic performance impact.

### 8.1 Operation Latencies

| Operation | Latency | Notes |
|-----------|---------|-------|
| **alloc_region (new page)** | 10 μs | Page fault + allocation |
| **alloc_region (same page)** | O(1) | Just SP adjustment |
| **alloc_ref** | O(1) | Bump allocate |
| **read_ref** | ~5 ns | Single load |
| **write_ref** | ~5 ns | Single store |
| **actor spawn** | 100-500 μs | Virtual allocation + initial 8 MB mapping |
| **actor migrate (context)** | < 1 μs | Atomic context switch |
| **first page access after migrate** | ~10 μs | Page fault + migrate |
| **actor terminate** | 1-10 ms | Depends on pages allocated |

### 8.2 Memory Efficiency

```
Example: 10,000 actors with average 50 MB stack

Virtual space overhead:
  10,000 actors × 1 GB virtual = 10 TB virtual (sparse, not backed)
  Cost to system: ~10 TB address space (typically available)

Physical memory cost:
  10,000 actors × 50 MB average = 500 GB physical
  Plus metadata: ~2 MB
  Plus guard pages: ~40 MB
  Total: ~500 GB (actual memory used)

Per-actor overhead:
  - Metadata: ~200 bytes
  - Guard page: 4 KB
  - Initial pages: 8 MB
  Total fixed overhead: ~8 MB per actor
  Variable: depends on runtime allocation
```

### 8.3 NUMA Characteristics

```
Best case (local allocation):
  - Memory access latency: ~10-20 ns
  - Bandwidth: ~90 GB/s (local NUMA node)

During migration (before page migration):
  - Cross-NUMA access: ~100-200 ns
  - Bandwidth: ~50 GB/s (reduced coherency)
  - Pages gradually migrate on access

After lazy migration (pages moved):
  - Back to local: ~10-20 ns
  - Recovery time: O(pages_accessed)
```

### 8.4 Scalability

| Metric | Scalability |
|--------|-------------|
| **Number of actors** | ~100,000 (limited by virtual address space + RAM) |
| **Actor stack size** | 8 MB initial; grows on demand with no default maximum; an optional per-actor limit |
| **Concurrent actors on one core** | ~1-10 (depends on workload) |
| **Actor creation rate** | ~10,000-100,000 per second (limited by malloc/virtual allocation) |
| **Message throughput per actor** | ~1M - 100M messages/sec (depends on message processing) |
| **Migration frequency** | Arbitrary (< 1 μs latency) |

---

## 9. Example Usage

### 9.1 Simple Actor

```silica
struct CounterMessage {
    value: int64
}

struct CounterState {
    count: int64,
    total: int64
}

fn counter_behavior(msg: CounterMessage, state: CounterState) -> CounterState {
    sequence proc[mem(normal)]
        // Allocate region within actor's stack
        r: region(R, normal) <- alloc_region(normal);

        // Store result in reference
        new_total_ref: ref(R, normal, int64) <-
            alloc_ref(r, state.total + msg.value);

        // Read back value
        new_total: int64 <- read_ref(new_total_ref);

        // Create updated state
        new_state: CounterState <- CounterState {
            count: state.count + 1,
            total: new_total
        };
    produces
        pure new_state
    end
}

fn main() -> atom {
    sequence proc[concurrency]
        // Spawn counter actor
        initial_state: CounterState <- CounterState { count: 0, total: 0 };
        counter: actor_ref <- spawn(initial_state, counter_behavior);

        // Send messages
        msg1: CounterMessage <- CounterMessage { value: 10 };
        send(counter, msg1);

        msg2: CounterMessage <- CounterMessage { value: 20 };
        send(counter, msg2);
    produces
        pure success
    end
}
```

### 9.2 Actor with Large Allocations

```silica
struct DataProcessingMessage {
    size: int64
}

fn data_processor(msg: DataProcessingMessage, state: State) -> State {
    sequence proc[mem(normal)]
        // Allocate region for large data
        r: region(R, normal) <- alloc_region(normal);

        // Allocate large buffer within stack
        // If size exceeds available stack: page fault -> growth
        buffer: buf(R, normal, int64, msg.size) <-
            alloc_buf(r, msg.size);

        // Process buffer (all operations on local stack)
        processed: int64 <- process_buffer(buffer, msg.size);

        // Create new state
        new_state: State <- State {
            result: processed,
            last_size: msg.size
        };
    produces
        pure new_state
    end
}

fn main() -> atom {
    sequence proc[concurrency]
        // Spawn with larger stack for this actor (optional)
        state: State <- State { result: 0, last_size: 0 };
        processor: actor_ref <- spawn(state, data_processor,
                                      stack_size: 1_GB);  // 1 GB stack

        // Send large data request
        msg: DataProcessingMessage <- DataProcessingMessage {
            size: 1_000_000  // 1M * 8 bytes = 8 MB
        };
        send(processor, msg);
    produces
        pure success
    end
}
```

### 9.3 Actor Migration

```silica
fn main() -> atom {
    sequence proc[concurrency]
        // Spawn actor on performance core
        state: State <- State { ... };
        actor: actor_ref <- spawn(state, behavior,
                                  core_affinity: performance_core(0));

        // Send messages (actor runs on perf core)
        send(actor, msg1);
        send(actor, msg2);

        // Later: migrate to efficiency core for power saving
        migrate_result: atom <- migrate_actor(actor, efficiency_core(0));

        case migrate_result of {
            success -> send(actor, msg3);  // Continues on new core
            failure -> handle_migration_error()
        }
    produces
        pure success
    end
}
```

---

## 10. Comparison: Old vs. New Model

### 10.1 Memory Model Comparison

| Feature | Old (Per-Actor Heap) | New (Growable Stack) |
|---------|---------------------|----------------------|
| **Memory allocation** | malloc/free | Stack pointer |
| **Region copy on spawn** | Yes (expensive) | No (no sharing) |
| **Cleanup on termination** | Manual, requires tracking | Automatic (free all pages) |
| **Stack size** | Fixed | Growable |
| **Migration cost** | ~ms (potential copy) | < 1 μs (lazy pages) |
| **Fragmentation** | Possible | None |
| **Allocator contention** | Yes (lock contention) | No (isolated stacks) |
| **NUMA efficiency** | Flexible but manual | Automatic (pages migrate) |
| **Compiler complexity** | Moderate | Low (stack semantics) |
| **Runtime overhead** | Allocator metadata | Guard page + metadata |

### 10.2 Behavioral Changes

```silica
// Old model required region copies on spawn
spawn(initial_state_with_region, behavior)
// Required deep copy of all region data

// New model: no copying
spawn(initial_state_with_region, behavior)
// Region passed directly to actor's stack
// Spawner still has handle (they're not shared)
```

```silica
// Old model: manual memory tracking
actor_memory: int64 <- calculate_actor_heap_usage(actor);
// Complex tracking of malloc'd blocks

// New model: simple accounting
memory_used: int64 <- get_actor_memory_usage(actor);
// Just sum of allocated pages
```

---

## 11. Implementation Roadmap

### Phase 1: Core Growable Stack (Weeks 1-3)

*Implemented 2026-09-17/18 on the hosted paths in the decided form (see Implementation status at the top); the sizes in the block below are the pre-decision ones.*

```
1. Virtual memory allocation
   - Per-actor 1 GB virtual r
   - Initial 8 MB physical mapping

2. Page fault handler
   - Detect guard page faults
   - Allocate new page on same NUMA node
   - Extend guard page

3. Actor spawn integration
   - Allocate stack instead of heap
   - Initialize metadata
   - Start execution loop

4. Actor termination
   - Deallocate all pages
   - Free virtual space
```

### Phase 2: Lazy Migration (Weeks 4-6)

*Not implemented: it applies only where the platform reports NUMA nodes. `migrate_actor` itself exists (ROADMAP chunk 2) and moves an actor's execution, not its pages.*

```
1. Extend page fault handler
   - Detect remote pages
   - Migrate on access

2. Actor migration API
   - migrate_actor() function
   - Move execution context only

3. Page location tracking
   - Per-actor NUMA mapping
   - Monitor migration overhead
```

### Phase 3: Optimizations (Weeks 7-8, optional)

```
1. Proactive page migration
   - Pre-migrate pages before access
   - Hint system for migrations

2. Multi-page faults
   - Batch migrate adjacent pages

3. Profiling and monitoring
   - Track page migration patterns
   - Guide optimization
```

### Phase 4: Compiler Integration (Weeks 2-8, parallel)

```
1. Code generation changes
   - Stack allocation instead of malloc
   - Growth checks before large allocs

2. Type system enforcement
   - No inter-actor r passing
   - ActorBoundary constraints

3. Error handling
   - Stack overflow handling
   - OOM handling
```

---

## 12. Comparison to Other Models

### 12.1 vs. Garbage Collection

| Aspect | Growable Stack | GC |
|--------|-----------------|-----|
| **Cleanup predictability** | O(1) on termination | Non-deterministic |
| **Latency pauses** | None (growth is incremental) | GC pauses (10s-100s ms) |
| **Memory usage** | Tight (only allocated) | Loose (fragmentation) |
| **Complexity** | Moderate (page faults) | High (GC algorithms) |

### 12.2 vs. Reference Counting

| Aspect | Growable Stack | Reference Counting |
|--------|-----------------|-----|
| **Cleanup** | Atomic (whole actor) | Per-object (gradual) |
| **Complexity** | Moderate | High (cycle detection) |
| **Memory overhead** | Per-actor | Per-object |
| **Cache locality** | Good (stack) | Poor (scattered refs) |

### 12.3 vs. Manual Memory Management (C/C++)

| Aspect | Growable Stack | Manual (C/C++) |
|--------|-----------------|-----|
| **Safety** | Type-enforced isolation | Manual discipline |
| **Cleanup** | Automatic | Manual (error-prone) |
| **Bugs** | Limited (type system) | Common (use-after-free) |
| **Performance** | Predictable | Variable |

---

## 13. Open Design Questions

### 13.1 Stack Sizing Strategy

**Question**: How should developers specify actor stack sizes?

**Options**:
- A: Fixed per-actor-type (e.g., "type LargeActor" → 1 GB stack)
- B: Dynamic at spawn time (e.g., `spawn(..., stack_size: 256MB)`)
- C: System heuristics (analyze behavior function statically)
- D: Hybrid (no default limit; an optional explicit limit at spawn time)

**Recommendation**: Option D (hybrid). The default is **unlimited**, bounded only by machine memory, which matches
spec §15.1.2.2. An explicit limit is opt-in.

### 13.2 Proactive Growth Hints

**Question**: Should developers provide hints about large allocations?

**Options**:
- A: No hints; rely purely on page faults
- B: Optional hints (e.g., `hint_stack_usage(100MB)`)
- C: Required analysis (compiler must predict)

**Recommendation**: Option B (optional hints, compiler can infer from types)

### 13.3 Migration Eagerness

**Question**: When should pages be migrated after actor migration?

**Options**:
- A: Pure lazy (only on access)
- B: Proactive (pre-migrate hot pages in background)
- C: Predictive (use ML to predict next access)

**Recommendation**: Option A initially, add B as optimization later

### 13.4 Error Messages for Stack Overflow

**Question**: How should actors handle stack overflow?

**Options**:
- A: Send exception message to actor behavior function
- B: Terminate actor immediately
- C: Suspend actor and retry later

**Recommendation**: Option A (send message, let actor decide)

---

## 14. Summary of Changes

### What Changed

1. **Memory model**:
   - Per-actor heap → Per-actor growable stack
   - Stack grows on demand via page faults
   - Pages migrate lazily when actor migrates

2. **Region semantics**:
   - No region copying on spawn (no inter-actor sharing)
   - Regions are stack-allocated, not heap-allocated
   - Region lifetime = actor lifetime (or scope within actor)

3. **Migration**:
   - Instant context switch (< 1 μs)
   - Pages migrate on first access (lazy)
   - No upfront copy overhead

4. **Cleanup**:
   - Automatic when actor terminates
   - All pages freed instantly
   - No manual tracking needed

5. **Compiler**:
   - Emit stack allocation instead of malloc
   - Enforce no inter-actor sharing at type level
   - Insert growth checks for predictable large allocations

### Benefits

- ✅ **Simpler semantics**: Isolation is automatic, cleanup is trivial
- ✅ **Better performance**: No allocator locks, perfect cache locality
- ✅ **Efficient migrations**: < 1 μs to move actors
- ✅ **NUMA-aware**: Pages naturally migrate to execution core
- ✅ **Unbounded allocations**: Grow within physical RAM
- ✅ **Scalable**: 100,000+ actors feasible

### Trade-offs

- ⚠️ **Page fault latency**: Growth/migration add ~10 μs overhead
- ⚠️ **Virtual space**: 1 GB reserved per actor (but sparse, not backed)
- ⚠️ **Unpredictable usage**: Hard to predict exact stack consumption

---

## 15. References

- Silica Specification: §12 Memory Model, §15 Actor Model
- AArch64 Architecture Reference Manual: Virtual Memory, Page Tables
- Linux Kernel: Signal Handlers, Page Fault Handling
- Lazy Page Migration: Research on NUMA-aware migration

---

**Document Status**: Phase 1 (§11) implemented on the hosted paths; Phases 2 and 3 not started (NUMA-only); see Implementation status at the top
**Next Step**: carriers (ROADMAP chunk 2) to lift the thread-per-actor bound; the NUMA phases when a NUMA target is taken up
