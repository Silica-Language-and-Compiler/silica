# Actor growable stack: implementation roadmap (plan)

Plan part split out of [actor_growable_stack_design.md](actor_growable_stack_design.md) (split 2026-11-15). The design, rationale and decisions stay in that file; the sections below are the plan, moved verbatim with their headings and numbering (references such as "design section N" point to the design file, and plan sections keep their original numbers).

Status: open work remains; this plan stays next to its design until every step is done.

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

*Status 2026-11-18: items 1 and 3 are done in the decided form. Stack allocation replaced malloc on the hosted targets (chunk 15 phases 4e and 8, see actor_memory_budget_plan.md), and stack exhaustion and a failed reservation are the failure reasons `(:explicit, :stack_exhausted)` and `(:explicit, :stack_reserve_failed)` (`trials/actor_stacks_addition`, `error_enforcement_addition/stack_policy_*`); the decided design has no runtime cap and no `:oom`.*
