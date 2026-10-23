# Region Memory Safety — Phase 1 TODO

This document describes what remains to be done to make Silica's region-based memory model memory-safe as specified. The specification (../silica-specification.md §12) defines comprehensive safety guarantees; the current implementation provides only partial support.

**Implementation status (2026-10-22, from the 2026-10-16 survey).** The design (§0) withdrew the premise that the 1,152 standard-library records with a region field become linear: they hold only never-freed family arenas, and linearity applies to owned regions (`alloc_region`) and aggregates embedding them.

**Status 2026-10-23.** Lee decided Q9 (a): inside an actor an out-of-bounds buffer index, an invalid buffer size and a list-index failure terminate the actor with `(:explicit, :buf_bounds)`, `(:explicit, :buf_invalid)`, `(:explicit, :list_index)`; only in `main` do they stay runtime abort 71. H5 (hosted region growth and raw allocation failure) likewise ends the actor with `(:explicit, :region_alloc_failed)` (Lee, 2026-10-22). H1, H3, H4, H5 and stage 8 are implemented on the Mac; the Linux and ESP32-S3 mirrors are written but unbuilt (staged hazard trials in `trials/region_hazards_open_addition`). E2313 and E2314 are registered; the `|bounds:N` metadata was removed.

**Next development set (Lee, 2026-10-22; not started at that date).** Chunk 4 work is ordered by what Project BEES needs: item 0 ports, runs and fixes the four BEES defect repros (SD-7, SD-20, SD-21, SD-22); then H1 (atomic canonical-arena bump and insert), H3 (let-bound aggregate passed by name), H4 (reply or state dangling after the replying actor ends), H5 (hosted arena grow failure and the missing null check in `emit_alloc_region`), stage 8 / Q9 (failures reach the supervisor instead of aborting), and S-15 (region release inside a living actor, stages 2 to 5 with the §18 move machinery). Items 1 to 5 need no open decision; S-15 rests on Q1, Q2 and Q5, decided by Lee on 2026-10-22: Q2 (a) the never-freed family arena (counted storage removed from the plan, so there is no stage 6; H4 therefore needs its targeted stage 0 fix), Q1 (a) the handle `arena(L, S)`, Q5 (a) per-actor owner lists. Q15 (a) `copy_to` builtin, Q16 (a) move a received region into state, Q17 (a) release on failed send are decided too, as is Q3 (a, 2026-10-23: a function may consume a region parameter without returning it) and Q4 (a, 2026-10-23: user functions cannot borrow in chunk 4), and Q7 (a, 2026-10-23: `region(L, atomic)` is the application-lifetime shared region, the one named exception to spec §12.1.6, on all targets), and Q8 (2026-10-23: the recommended atomic surface of design §9.2, no `alloc_atomic`, four `atomic_*` builtins with atom orderings), and Q10 (a, 2026-10-23: implicit per-signature quantification of lifetimes, no `L: lifetime` value parameters), and Q11 (a, 2026-10-23: a linear type may not instantiate a generic type parameter, list element type or trait associated type, E2307); and Q13 (2026-10-23: reading a version stored inside a structure returns a structural copy built like `copy_to`; O(size) per read, never freed; copy destination and spelling still open); and Q14 (2026-10-23: the child spec may hold a version and the child receives a copy at every start and restart, released when it dies; copy destination, type spelling and cost are open details). Q18 (Lee, 2026-10-23, option C): messages copy by default and move only on request (spelled `move`); E2301 then applies to explicitly moved values only (design §15). Messages that carry regions are planned by design §18.7 (2026-10-22): moved on send (now: the sender's copy moves, or the original on an explicit `move`), dispatch-scoped in the receiver, kept only by moving the whole region into the state or by an explicit `copy_to`, with release on the failure paths (failed send, mailbox drain at actor end, dead or timed-out caller). Full list: the "Next development set: region safety for Project BEES" section of [participate.md](../../../docs/participate.md).

**Earlier status (2026-10-16).** The plan below is the 2025-2026 gap list. The chunk-4 design
([region_memory_safety_design.md](../region_memory_safety_design.md), ROADMAP chunk 4) supersedes it for everything
not yet built: static lifetime analysis beyond Phase A (§2.1), region isolation (§2.3), ownership-based release and
the use-after-free hazards (§2.4), and atomic references (§2.5) are all still open, and none of the design's
error codes (E2300 to E2318) or `drop` nodes exists in the compiler. One item is done: buffer bounds checking
(§2.2), emitted on all four targets since 2026-09-19. File paths below are relative to `compiler/src`, and the
emitter files exist once per target, as `emitter/<target>/terms/prims/prims_memory.silica`.

## Related Documents

| Document | Purpose |
|----------|---------|
| [silica-specification.md](../silica-specification.md) | Core language specification, §12 Memory Model |
| [specification-analysis-state.md](../../specification-analysis-state.md) | Region analyzer component requirements |

---

## Terminology: memory region vs arena

In Silica, **memory region** (often **region**) is a typed allocation unit: `region(L, Space)` with a lifetime identifier `L`, a memory space `Space` (`normal`, `atomic`, `device`, ...), and static region lifetime analysis (see [silica-specification.md](../silica-specification.md) §12).

In many other languages, **arena** names an allocator *pattern*, not a full type-system feature: a pool of memory from which objects are suballocated in bump or stack order and typically reclaimed together when the arena is reset or destroyed. Examples include C/C++ per-request or per-object arena allocators, Rust crates such as `typed-arena` or `bumpalo`, and JVM thread-local allocation buffers (sometimes called arenas). Some garbage collectors also use **arena** for age-based or nursery subspaces.

**Silica memory regions vs those arenas:** A Silica region is not merely an arena allocator under another name. Regions are first-class types with lifetime parameters, integrate with effects (`mem(Space)`), and are verified by the compiler. A concrete implementation may use bump allocation *inside* a region’s backing storage—similar to *how* a classic arena works—but that is representation detail, not the definition of *region* in the language.

---

## 1. Current Implementation Status

### 1.1 What Is Implemented

| Component | Location | Status |
|-----------|----------|--------|
| Region type syntax validation | `type_checker/type_checker_memory_regions.silica` | ✓ Validates `ref(R, Space, T)`, `region(R, Space)`, `buf(R, Space, T, N)`; `atomic` is accepted as a memory space. Legacy `atomic_ref` may still parse. |
| Memory space validation | Same | ✓ Validates `normal`, `normal_writeback`, `normal_writethrough`, `normal_noncacheable`, `atomic`, `device` |
| Effect tracking for region ops | `effect_checker/effect_checker_memory_regions.silica` | ✓ Requires `mem(Space)` for `alloc_region`, `alloc_ref`, `read_ref`, `write_ref`, etc. |
| SIR prim generation | `sir_generator/terms/memory_region_calls.silica` | ✓ Maps current region built-ins to SIR prim terms; `alloc_atomic` is not implemented as a SIR prim |
| Code emission | `emitter/<target>/terms/prims/prims_memory.silica` (four targets) | ✓ Emits alloc/read/write (heap bump; see §1.2) and the buffer bounds check (§2.2); atomic-space refs still lower through ordinary memory prims |

### 1.2 Current Allocation Strategy

Each **memory region** is implemented in `prims_memory.silica` as a heap-allocated block with bump-pointer metadata at the base (see emitter comments for layout). This matches the spec’s model of scope-tied deallocation better than an earlier stack-only sketch, but remains a minimal prototype:

- `alloc_region`: obtain a block (e.g. via `malloc`), initialize bump/end pointers
- `alloc_ref` / `alloc_buf`: bump-allocate within that block, with overflow checks to the region overflow path

Terminology: [memory region vs arena](#terminology-memory-region-vs-arena) (above). Without lifetime analysis, the compiler cannot fully prevent returning or storing references that would become dangling after the backing storage is released or invalidated.

---

## 2. Gaps — What Must Be Implemented

### 2.1 Static Region Lifetime Analysis (Critical)

**Specification**: §12.1.4 Static Region Lifetime Analysis

**Status**: ⚠️ Phase A implemented; Phases B and C pending (checked 2026-10-16: `check_sequence_return_lifetime` in `type_checker_memory_regions.silica` is still the only lifetime rule; design in [region_memory_safety_design.md](../region_memory_safety_design.md) §4, §5)

**Phase A (implemented)**: Single-scope lifetime analysis in `type_checker_memory_regions.silica`:
- When a sequence returns, any `ref(L,...)`, `buf(L,...)` (including `ref(L, atomic, ...)` for atomic space), or legacy `atomic_ref(L,...)` in the return type must have `region(L,...)` in the return type (scope exit rule).
- Error E2100: "reference outlives region" when returning references without the region. (E2100 is also emitted by `ffi/ffi_taint_checker.silica` for external-danger taint, the only meaning `error_codes.md` registers; the design's §10 moves the region meaning.)

**Phases B and C (not yet implemented)**: Must be implemented after functions are fully supported:
- **Phase B**: Nested scopes — extend L and ScopDep across nested blocks and sequences.
- **Phase C**: Cross-function analysis — function parameter lifetime extension, function return lifetime constraint, region return lifetime extension.

**Required** (full implementation): The compiler must perform static analysis to verify that:

1. References cannot outlive their containing region
2. Region deallocation occurs only after all references are no longer accessible
3. Function returns of references require the region to outlive the call
4. Cross-function and cross-module lifetime constraints are respected

**Formal framework** (from spec):

- **Lifetime environment**: `L ::= ∅ | L, R:scope` — maps region identifiers to lexical scopes
- **Dependency set**: `D ::= ∅ | D, ref(R, Space, T):scope` — tracks references and creation scopes
- **Judgment**: `Γ; L; D ⊢ e : T; L'; D'`

**Key rules to implement**:

- Region Allocation Rule: Add region to `L` at `alloc_region`
- Reference Allocation Rule: Verify region in `L`, add ref to `D` at `alloc_ref`
- Reference Usage Rule: Verify region and ref exist, scope constraints hold at `read_ref`/`write_ref`
- Scope Exit Rule: Remove regions/refs, verify no dangling references
- Function Parameter Lifetime Extension: Regions passed as parameters extend to return scope
- Function Return Lifetime Constraint: Returning `ref(R, Space, T)` requires region outlives call

**Planning reference**: The region analyzer work has historically been tracked as Phase 6, tasks 6.1.1–6.5.2. There is no `build-plan.md` file currently present on disk, so this TODO is the active Phase 1 tracking location for these gaps.

---

### 2.2 Buffer Bounds Checking (Critical)

**Specification**: §12.3.3 Bounds Checking, §14.4.1 Bounds Checking

**Status**: ✓ Implemented 2026-09-19 on all four targets (the entry below is kept as the record of what was required)

**As built**: `alloc_buf` stores the element count in the word below element 0 and rejects a negative count or a byte-size overflow (`L_buf_invalid`, runtime abort `invalid buffer size`). Every `buf_store` and `buf_load` compares the index against that count (`emit_buf_bounds_check` in `prims_memory.silica`: `LDR X17, [X1, #-8]; CMP X2, X17; B.HS L_buf_bounds`) and branches to `L_buf_bounds`, which ends the process with the runtime abort `buffer index out of bounds`, status 71 ([runtime_failure_reporting.md](../runtime_failure_reporting.md) §4). Trials: `memory_region_addition/buf_write_out_of_bounds_aborts` and `buf_read_out_of_bounds_aborts`.

**Not done**: the check uses the run-time count, not the `N` of `buf(R, Space, T, N)`, so the size passed to `alloc_buf` is never compared with `N` (design §1.1). The spec says an out-of-bounds access is a trap; the process-wide abort, even inside an actor, against "crash to the supervisor" was decision Q9 in the design (§1.5, S5), **decided by Lee, 2026-10-23: (a), the actor ends (`:buf_bounds`, `:buf_invalid`, `:list_index`), abort 71 only in `main`**. The `|bounds:N` metadata was removed; the run-time check stays for every index.

---

### 2.3 Region Isolation Enforcement (High)

**Specification**: §12.4.1 Region Isolation

**Status**: ⚠️ Partial — type syntax is validated, but semantic checks are not enforced

**Required**: The type system must prevent:

1. Using a `ref(R1, Space, T)` with a `region(R2, Space)` when R1 ≠ R2
2. Creating cross-region references (e.g., `ref(R2, normal, ref(R1, normal, int))` when R1 ≠ R2)

**Current gap**: The type checker validates that `ref(R, Space, T)` is well-formed but does not:

- Verify that `alloc_ref(region, value)` receives a region whose type's R matches the result type's R
- Unify region identifiers across function boundaries (e.g., when passing regions as parameters)
- Reject mixing regions in invalid ways

**Implementation**: Extend type checker to:

- Track region identifier R from region-typed expressions
- When type-checking `alloc_ref(region_expr, value_expr)`, require `region_expr : region(R, Space)` and result `ref(R, Space, T)` with same R
- When type-checking `read_ref(ref_expr)` / `write_ref(ref_expr, value)`, ensure ref_expr's R is in scope
- Reject programs where R in ref does not match R in the corresponding region

---

### 2.4 Allocation Strategy and Use-After-Free (High)

**Specification**: §12.1.2 Region Lifetime, §12.4.2 Lifetime Safety

**Status**: ❌ Without complete lifetime analysis, use-after-free is still possible when a region’s storage is released while references remain

**Problem**: When a function or sequence ends, a region’s backing storage may be released per scope rules. Any reference to that storage becomes invalid. Without lifetime analysis, the compiler cannot reject:

```silica
fn leak_ref() -> ref(R, normal, int64) {
    sequence proc[mem(normal)]
        r: region(R, normal) <- alloc_region(normal);
        ref: ref(R, normal, int64) <- alloc_ref(r, 42);
    produces
        pure ref   // BUG: ref outlives its region (storage may be freed when scope ends)
    end
}
```

**Required**:

1. **Lifetime analysis** (see §2.1) must reject returning references whose region does not outlive the function
2. **Allocation strategy**: Enforce (via lifetime analysis) that no ref outlives its region; keep heap-backed regions with deallocation tied to scope exit as the spec implies (see §1.2)

The spec describes "implicit deallocation when r goes out of scope" — the implementation must ensure no references remain when that happens.

---

### 2.5 Atomic references (`ref(R, atomic, T)`) (Medium)

**Specification**: §4.4.5 Atomic memory space and `ref`, §17 Atomic Operations

**Status**: ⚠️ `ref(R, atomic, T)` is type-checked and participates in `mem(atomic)` effect handling, but full atomic lowering is not complete. `alloc_atomic` is specified in the documentation but, by Lee's Q8 decision of 2026-10-23, is not to be added (atomic cells come from `alloc_ref` into a `region(L, atomic)`); the atomic surface of design §9.2 is not implemented in the compiler source as a region built-in, SIR prim, or Apple Silicon memory prim.

**Required**: Implement and verify complete support for **`ref(R, atomic, T)`** and the §9.2 surface (no `alloc_atomic`):

- Type checker accepts **`ref`** with **`atomic`** space ✓
- Effect checker handles `mem(atomic)` and emits function/call barriers where currently wired ✓
- `alloc_ref(atomic_region, initial)` and the four `atomic_*` builtins (atom orderings, E2315/E2317) are recognized by the type checker and effect checker
- SIR generation lowers them to atomic-capable prims
- Code emission uses correct atomic load/store/compare-exchange operations where required, not only plain `LDR`/`STR`
- Memory ordering semantics per §17.2

**Note:** The redundant **`atomic_ref(R, Space, T)`** type constructor is **not** used for new code; **`ref(R, atomic, T)`** carries the same enforcement via the memory space parameter.

---

## 3. Implementation Order

The 2025 ordering that stood here (bounds, isolation, lifetime analysis, allocation strategy, atomics) is replaced by the
stage list of [region_memory_safety_design.md](../region_memory_safety_design.md) §13, with the work split in §16.
Status as of 2026-10-22: the bounds item is done; the stages below are not started, per the design (not re-verified
against the tree beyond the 2026-10-16 survey recorded in its status paragraph).

| Stage | Content | Needs |
|-------|---------|-------|
| 0 | Silent hazards H1 to H10 (design §1.3): atomic arena bump, `cast`/`send`/`spawn` as moving prims, let-bound aggregate promotion, null checks (H5: the actor ends with `(:explicit, :region_alloc_failed)`, abort 71 in `main`). H1, H3, H4, H5 implemented on the Mac 2026-10-23, mirrors unbuilt | no decision |
| 1 | Lifetime polymorphism (per-call substitution, E2311); covers the Phase B/C part of §2.1 | Q10 decided 2026-10-23 (a): implicit per-signature quantification |
| 2 | Structure handle type `arena(L, S)`, no cell ever freed. **Waits on ROADMAP chunk 15** (data structure redesign, 2026-10-23), which decides where structure memory lives and who releases it | Q1, Q2 (decided 2026-10-22); chunk 15 |
| 3 | Region checker, report-only (isolation §2.3 and linearity for owned regions) | stage 2 |
| 4 | `drop` nodes and runtime owner lists (use-after-free, §2.4) | Q5 (decided 2026-10-22) |
| 5 | Errors on (E2300 to E2318) | none (Q3, Q4 and Q11 decided 2026-10-23) |
| 7 | Atomics (§2.5): builtins, lowering, shared atomic regions | none (Q7 and Q8 decided 2026-10-23) |
| 8 | Bounds outcome (actor failure, not process abort) and static checks against N (§2.2, "Not done"). Q9 decided 2026-10-23; outcome implemented on the Mac, mirrors unbuilt; E2313/E2314 registered | Q9 (decided) |

- **Owned by ROADMAP chunk 15 (2026-10-23):** the two bullets below (Q13, Q14 open details) are decided there, as part of the data structure redesign, which is a prerequisite for stage 2.
- **Open detail of Q13 (stage 4, beside `copy_to`):** a structural-copy read of an inner structure version (a graph's adjacency set from `get`) needs Lee to settle (1) which arena receives the copy, the caller's arena or the inner type's family arena, and (2) the spelling, an explicit `copy_to`-style call or `get` copying implicitly. Do not implement until decided. Queries (`has_edge`, `neighbors`) need no copy.
- **Open details of Q14 (stage 4, supervisor spawn; decided by Lee 2026-10-23: a copy is sent to the child at start and cleaned up when the child dies):** the child spec may hold a structure version and each start and restart gives the child a `copy_to`-style structural copy, released at the child's death. Do not implement until Lee settles (1) the copy cannot live in the never-freed family arena of Q2 (a); it must be in a region the child owns, freed by the Q5 owner list, so the type spelling and its relation to `arena(L, S)` and to Q16 (a received region moving into state) are undecided; (2) the cost is O(size of the version) per start and restart (restart storms); (3) whether the supervisor at spawn or the runtime on spawn makes the copy, and its destination; (4) whether Q2 (a) needs a per-instance exception for structures that must be freed (for Lee). E2308 stays for owned regions.

Stages 0, 1 and 8 need no open decision. There is no stage 6 (the counted-storage stage was removed, Q2 a, 2026-10-22). Hosted carriers (ROADMAP item N) are the execution model; owner lists belong to
the actor, so they do not change this order.

---

## 4. Verification Checklist

When implementation is complete, the following should hold:

- [ ] No program can return a reference whose region does not outlive the call (lifetime analysis; design stages 1, 3, 5)
- [ ] No program can use a reference after its region has been deallocated (lifetime analysis and drop-based release; design stages 3 to 5)
- [x] No `buf_load` or `buf_store` executes without a prior bounds check (bounds checking; 2026-09-19, against the buffer's run-time count)
- [ ] No `ref(R1, ...)` is used with `region(R2, ...)` when R1 ≠ R2 (region isolation; design stages 3 and 5)
- [ ] Cross-module region usage is validated (cross-module lifetime tracking)
- [ ] (design stage 7) the Q8 atomic surface (§9.2) is implemented end to end
- [ ] Atomic-space refs use correct atomic load/store/RMW lowering and documented ordering semantics
- [ ] Error messages reference specification sections (e.g., spec:§12.1.4)

---

## 5. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-03-10 | Initial document; gaps identified from implementation analysis |
| 1.1 | 2026-03-27 | Terminology: memory region vs arena; §1.2/§2.4 aligned with heap bump emitter |
| 1.2 | 2026-05-26 | Moved into `Phase1_TODOs`; aligned atomic status with source-code audit |
| 1.3 | 2026-10-16 | Status block: superseded by the chunk-4 design; bounds checking (§2.2) marked implemented; paths made per-target |
| 1.5 | 2026-10-23 | Q9 decided (a) and H5 outcome recorded; stage 0 and 8 status; E2313/E2314 registered; `\|bounds:N` removed |
| 1.4 | 2026-10-22 | §3 Implementation Order and the checklist now point to the design's stage list (§13); status block: the withdrawn linearity-of-1,152-records premise noted; carriers noted |
