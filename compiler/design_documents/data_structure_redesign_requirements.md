# Data structure redesign: requirements (ROADMAP chunk 15)

**Date:** 2026-10-23
**Status:** Requirements only. Chunk 15 is not started. No solution is chosen here; the choices that remain are marked for Lee.
**Written at:** Lee's request, after he said he is not happy with the current design of the standard data structures and wants it deeply revised as a chunk.
**Related:** ROADMAP.md rows 4 and 15; [region_memory_safety_design.md](region_memory_safety_design.md) §0, §3.1, §3.13, §3.14, §7, §15, §18.7; [data_structure_designs/README.md](Phase1_TODOs/data_structure_designs/README.md); `compiler/stdlib/data_structures/`.

## 1. Purpose and status

Chunk 15 replaces the storage and ownership model of the standard data structures. The ~21 families in `compiler/stdlib/data_structures` were built on one model: every value of a family allocates its nodes from one application-lifetime arena per family, obtained from `canonical_arena_lookup`, and that arena is never freed. Decision Q2 (a) of 2026-10-22 kept that model. Q13 and Q14 of 2026-10-23 need structure copies that can be freed, and Lee is dissatisfied with the model as a whole. Chunk 4 stage 2 (the structure handle type `arena(L, S)`) waits on this chunk.

This document records what the redesign must satisfy and the question it has to answer. It does not pick an answer.

**Changelog.** 2026-10-23: R4 revised to Q18 (copy by default, move on request); consistency pass afterwards: section 4 (A) and (B), section 5 items 1, 3 and 10 brought in line with R4, R4.1 and R4.2.

## 2. Lee's requirements (binding)

**R1. Earlier decisions stand.** Every decision of 2026-10-09, 10-22 and 10-23 below remains part of the redesign and is not provisional. (Q12 was withdrawn as moot under Q2 (a); see R1.1.)

| Q | Decided answer |
|---|---|
| Q1 | The structure handle is a new non-linear type constructor `arena(L, Space)`; a script renames the stdlib fields from `region(L, normal)`. |
| Q2 | (a) The never-freed family arena with the atomic bump (stage 0). **In tension with Q13 and Q14; the redesign must resolve it (R1.2).** |
| Q3 | A function may consume a region parameter without returning it; E2305 stays reserved and unused. |
| Q4 | User functions cannot borrow; only the region prims borrow. A function that inspects a linear value takes it and returns it. |
| Q5 | A per-actor runtime owner list releases owned regions when an actor ends; ownership transfers on message and spawn. |
| Q6 | Messages move, not copy. An owned region in a message, reply or spawn state is moved and the sender's later use is E2301. **Superseded as the default by Q18 (2026-10-23): a send copies by default and moves only on request; E2301 then applies only to explicitly moved values.** |
| Q7 | `region(L, atomic)` may be shared between actors, on all targets. |
| Q8 | The atomic surface of design §9.2 (four `atomic_*` builtins, literal orderings, tagged-tuple CAS result). |
| Q9 | An out-of-bounds buffer access, invalid buffer size, list-index failure, region growth failure and raw allocation failure end the actor; abort 71 only in `main`. |
| Q10 | Lifetime polymorphism is implicit per-signature quantification; conflict is E2311. |
| Q11 | A linear (owned-region) type may not instantiate a generic parameter, a list element type or a trait associated type: E2307. |
| Q13 | Reading an inner structure out of a container (for example a graph's inner adjacency set from `get`) returns a **structural copy** built the way `copy_to` builds one, not the stored handle. |
| Q14 | A supervised child's spec may hold a structure. The child receives a **copy** at every start and restart, and the copy is released when the child dies. E2308 stays for owned regions. |
| Q15 | `copy_to(region, value)` is a compiler builtin derived per type like `recreate`; no copy for `device_window` or atomic cells. |
| Q16 | A behaviour may move a whole received region into its state (the state owns it, no drop, O(1)). |
| Q17 | On a failed send the runtime releases the moved region; a sender that needs the data copies first. |
| Q18 | (2026-10-23) A send copies by default, for structures and owned regions, and moves (spelled `move`) only on request; function calls still move. See R4. |

R1.1. Q12 (how to send a version one also keeps) was withdrawn on 2026-10-22 because under Q2 (a) a version is a copyable handle. If the redesign changes what a version is, the question it answered may return; that is part of section 5.

R1.2. **Q2 (a) against Q13 and Q14.** Q2 (a) says structure memory is never freed. Q13 produces a copy on every read of an inner structure, and Q14 produces a copy per child start that "is released when the child dies". A copy that is released cannot live in a never-freed arena. The redesign must resolve this. The design document §15 Q14 lists the options Lee has so far not chosen between: an exception to Q2 (a) for structures that must be freed, or a different storage model.

**R2. Functional design stays.** The structures remain functional, as their design documents describe: persistent, immutable versions; an update returns a new version.

**R3. Reuse, and the old version survives.** An update or addition REUSES the elements (nodes) of the old structure in the new one; it does not copy them. The old structure is NOT destroyed by the update.

**R4. Sendable: messages copy by default, move on request; function calls move.** (Lee, 2026-10-23, "option C", design Q18; this replaces the earlier "by move, not copied, not shared" for messages.) A send (cast, call message, reply, spawn state) COPIES its value by default, for data structures and owned regions; the sender keeps its data. A value the code explicitly marks for moving is transferred in O(1) and the sender may not use it afterwards (E2301 applies only to explicitly moved values). Function calls are not changed: they still MOVE.
The explicit move is spelled `move` (Lee, 2026-10-23: decided). The compiler's legacy `move` builtin (an old actor-migration alias; migration is `migrate_actor`) is being removed, so there is no collision.

R4.1 **How the copy works** (recommended, accepted as part of C; the design direction). The sender copies the message into a fresh owned region, and that region then moves to the receiver. The decided machinery therefore applies unchanged: the dispatch-scoped message region dropped at behaviour return unless moved into state (design §18.7, the SD-7 work stays valid), Q16 move into state, Q17 failed-send release, the mailbox drain. Copying is type-directed: tree-shaped parts are walked with no bookkeeping; a per-message table (source node address to copy) is kept only where the type allows sharing. A raw owned region is copied by traversal from the message's typed roots, not by memcpy, because it holds internal pointers. A later optimisation, only if measured to be needed: in-place forwarding with an undo log (valid because the sender's data is private and the sender does the copy; it needs a spare word or bit per node, which the boxed one-word-per-field record layout may not have, and it cannot write read-only constants).

R4.2 **Sharing is preserved** across every value in one message, including two versions of a structure sent together (Lee, 2026-10-23: yes). One node in the source is one node in the copy. The per-message table is therefore required wherever the type allows sharing. This also answers whether `copy_to` preserves internal sharing for messages.

R4.3 **Evacuation under candidate D** (return from a frame, copy into state at dispatch end). The source frame is dying, so forwarding pointers may be written into it and no table is needed; sharing is still preserved. Non-tail recursion would copy a returned version once per frame (quadratic). The direction is destination-passing: build directly where the result is kept, as region passing does, when the compiler can see the value flows to the return; evacuation otherwise. Lee's cleanup-on-pop rule is unchanged.

## 3. How Erlang and the BEAM do it

For comparison only.

- Terms are immutable. Within one process heap, an update builds new cells and shares the unchanged ones with the old term (structural sharing).
- Each process has its own heap with a copying, generational garbage collector. An old version stays alive until nothing reaches it, then the collector reclaims it.
- A message is deep-copied into a heap fragment that the receiver owns. The sender keeps its own copy. Sharing inside the term is not preserved by the copy (a term referencing one subterm twice arrives as two copies).
- A call inside a process passes pointers; nothing is copied.
- Reference-counted binaries over 64 bytes live off-heap and are shared between processes by reference counting.
- ETS copies terms into the table on insert and out of it on lookup.

So the BEAM gets reuse through sharing inside one process and isolation through copying between processes, and it never moves. It needs a garbage collector to know when a shared node is dead. Silica has no garbage collector. Since 2026-10-23 (Q18) Silica's messages copy by default as the BEAM's do, with an explicit move on request, and function calls still move. Unlike the BEAM, a Silica copy preserves sharing inside a message, and the copy goes into a fresh owned region that then moves to the receiver.

## 4. The central tension

R2, R3 and R4 together:

- R3 says the new version contains nodes of the old version.
- R3 also says the old version stays valid after the update.
- R4 (as first stated) said a send moves the structure. Since 2026-10-23 a send copies by default, so the tension below applies to an EXPLICIT move and to function calls, which still move.

If the sender moves the new version away while still holding the old one, the moved version shares nodes with a version the sender still uses. The nodes cannot be both moved and shared. Either something larger than the one version is moved, or the sender is stopped from keeping the other versions, or the sharing is broken.

Candidate resolutions. None is chosen; **this is for Lee to decide.**

**(A) Move the whole family.** All versions derived from one structure live in one owned region. A send moves the region, with every version in it, in O(1). The old version is intact, but now at the receiver.
- Satisfies: R2 and R3 in full; R4 for an explicit move (moved, O(1)), while a default send copies the family or the version (R4.1); fits the Q5 owner list, Q6 and Q16, since the unit that moves is an owned region.
- Breaks or costs: the sender loses every version of that structure, including old ones it may still want, and its later uses are E2301. The unit of ownership is the whole family, not the version, so a program cannot hand one version away and keep another of the same family. Nothing frees a node inside the region while the region lives, so memory in a long-lived region grows with every update unless some separate reclamation is added (not designed). The region is linear, which interacts with Q11 (see section 5).

**(B) Exclusive ownership at send.** A send is legal only if no other live version shares nodes with the version being sent; the send then moves the nodes.
- Satisfies: R2, R3, R4 for the programs it accepts; reclamation would follow from knowing when a node has no other owner.
- Breaks or costs: knowing "no other live version shares these nodes" needs counting (reference or ownership counts on nodes, or an equivalent). An earlier design (the counted-storage stage, design §17) tried counting and was rejected and removed. Whether it can be checked statically is unknown; the dynamic form costs space and time on every update. For an explicit move, a send that finds sharing would be an error or a copy; which is not decided. (A default send copies in any case, R4.1.)

**(C) Consume the old version on update.** An update takes the old version and returns the new one; the old version can no longer be used.
- Satisfies: R2, R4, and makes ownership simple (one live version per lineage, so a send is plain).
- Breaks: R3's second half, that the old version is not destroyed, and with it persistence as the designs describe it (design §3.14 "A change does not consume its input", and 149 trial updater calls that reuse old versions). Listed because it is the obvious alternative; it contradicts a stated requirement.

**(D) The BEAM pattern with structures kept in the actor's stack.** Structures live in the actor's stack (per-actor, runtime-managed, released at the message boundary under the `stack_policy` algorithms), not in a heap or family arena.
- Gives: release is free, at a frame pop or the message boundary; no per-structure bookkeeping; no never-freed arena; the returned-record leak (H9) goes away. New versions reuse old nodes inside an actor and the old version stays intact (R2, R3). Q13 falls out: reading an inner structure from state copies it into the working area, as the BEAM does reading ETS. Q14 falls out: the spec holds the original, each start copies it into the child's memory, freed at death. No linearity is needed for structures inside one actor.
- Rule for returns (Lee, 2026-10-23): a version created in a callee's frame and not returned before the frame pops is cleaned up. This is the same rule as design §3.3 (an owned value not returned or moved is dropped at scope end), with "moved" meaning "evacuated to the caller".
- Mechanism to record: nodes allocated in the callee frame vanish on the pop. Old versions are safe because immutable structures never point from old nodes to new ones. A RETURNED version is evacuated on return by copying only the nodes whose addresses lie inside the frame being popped, leaving pointers to older nodes (the caller's or the state's) alone. Reuse is kept and the cost is proportional to the new nodes (O(log n) for a persistent update). Intermediate versions unreachable from the result are never copied. The alternative is to allocate in the caller's area, as region passing already does.
- Breaks or open: a stack-resident structure cannot be moved to another actor in O(1), because the stack is one contiguous per-actor reservation. A send therefore copies (decided 2026-10-23, R4: copy by default, sharing preserved, the copy built in a fresh owned region that moves to the receiver). An explicit move of a stack-resident structure needs it built in an owned region. Surviving a dispatch into state is a copy, and it must preserve sharing (decided for messages, R4.2; evacuation uses forwarding pointers in the dying frame, R4.3) or a shared structure blows up. Structures must be immutable: a mutable ref cell holding a structure could point into a popped frame, so an E2300-style rule is needed. Stack peak follows the largest dispatch, and `:keep_high_water`-style policies keep it.
- Not verified: where actor state lives today. It is believed to be in the actor control block outside the stack; check this before relying on it.

Combinations or other options may exist. The list above is what has been identified, not a proof of completeness.

## 5. Consequences and questions the design must answer

1. **Where does a structure's memory live, and who releases it?** Today: the family arena, never freed. Q13 and Q14 need releasable copies. Q5 releases owned regions by the actor's owner list. The design must say, for each of: a version made by an update, a Q13 read copy, a Q14 start copy, a `copy_to` copy, a structure received by message (a copy by default, R4.1; an original only on an explicit `move`).
2. **Q5 owner lists.** If structure memory is an owned region, the owner list covers it, and a crashed actor's structures are released. If it is not, say what releases it.
3. **Q15 `copy_to` and Q16 move into state.** How does a structure interact with `copy_to` (rebuild in the state's region, O(size); sharing is preserved for messages, R4.2)? May a received structure's region move whole into state? Under (A), a received structure is a region, so Q16 applies directly. Under (B), (C) and (D) a received structure arrives as the receiver's copy in a fresh owned region (R4.1) or as an explicitly moved original, so Q16 can apply to that region; how a stack-resident structure (D) does so is open.
4. **Q11.** A linear type may not instantiate a generic parameter. Every stdlib structure is generic in its items. If a structure is, or embeds, an owned (linear) region, then `wbt_map[K, V]` over linear items is rejected, but also the question is whether a structure type itself may be passed through generic code, which the stdlib needs everywhere. The redesign must say how a structure value is typed so that generic stdlib code and Q11 coexist. Not analysed here.
5. **Q10.** Lifetime names in structure signatures under implicit quantification: today 9,428 uses of `L` are reported in design §15 Q1; how a structure's lifetime relates to the owned region it lives in is open.
6. **Returned-record leak (H9).** H9 lists owned-region leaks, among them regions inside a record or tuple and regions held by an actor that crashes. This chunk takes it over (ROADMAP row 15).
7. **Change-result reshaping (design §3.14).** Changes return `:unchanged | (:tag, V)` sums, a no-op returns `:unchanged`, and about 367 updaters, about 300 caller sites in `trials/` and 55 in the compiler are affected. Not scheduled in any stage; this chunk takes it over. Whether the new model changes the result shapes (for example if an update can consume its input under (C)) is open.
8. **Q13 open details (Lee has not decided).** (1) Which arena or region receives the copy: the caller's, or the inner type's family arena. (2) Spelling: an explicit `copy_to`-style call, or `get` copying implicitly. Cost: O(size of the inner structure) per read; a loop of reads over a graph is quadratic in the worst case; `has_edge` and `neighbors` need no copy.
9. **Q14 open details (Lee has not decided).** (1) The copy's type and its relation to `arena(L, S)` and to Q16 (state then holds data in an owned region, not an `arena` handle). (2) Cost O(size) per start and restart, which matters in restart storms. (3) Who makes the copy: the supervisor at spawn, or the runtime on spawn. (4) The copy's destination. (5) Whether Q2 (a) gets an exception for structures that must be freed.
10. **Sharing inside moved and copied values.** Nodes of one version are shared with other versions (R3). What `copy_to` does with shared nodes inside one structure (preserve or duplicate) is decided for messages (preserve, R4.2); for the stand-alone `copy_to` and the Q13 and Q14 copies it is presumed the same but is to be confirmed (7.2 item 9), and it affects their cost.
11. **Concurrent access.** Today the family arena has a shared bump pointer and insert table, made atomic in stage 0 (H1). Whether the new model still has any shared mutable allocator state is open.
12. **Families that do not use nodes.** CSR and dense graph snapshots store `buf(...)` buffers plus a WBT slot map; skew-list and others store cells. The model must cover all of them, or say which are excluded.

### 5.1 How the current families store their nodes

From the design documents and a read of `compiler/stdlib/data_structures` (I read the headers and signatures of `wbt_map.silica`, `graph_csr_core.silica`, `skew_ral_node.silica` and grepped the rest; I did not read the implementation of every family).

- The design suite states that recursive nodes are region-allocated and referenced through `ref?(L, normal, rec)`, with `:none` as the empty position; that every constructor uses the canonical application-lifetime arena for its generated representation specialization and memory space; and that the collection value carries the arena capability.
- `canonical_arena_lookup` appears in 11 files: `wbt_map`, `wbt_set`, `brodal_okasaki`, `skew_ral`, `tree_binary`, `tree_rose`, `graph_csr_core`, `graph_wbt_directed`, `graph_wbt_undirected`, `graph_weighted`, `graph_weighted_undirected`. The trait files (`OrderedMap`, `Heap` and so on) are thin; I did not check how each delegates.
- Families by file prefix and design: Adams-family weight-balanced trees (`wbt_map`, `wbt_set`, behind `OrderedMap`, `OrderedSet`, `SearchTree`); Brodal-Okasaki skew-binomial queues (`brodal_okasaki_*`, behind `Heap`, `PriorityQueue`); skew-binary random-access lists (`skew_ral_*`); rose and binary trees (`tree_rose`, `tree_binary`, `Tree`, `BinaryTree`); live WBT graphs (`graph_wbt_*`, `graph_weighted*`); CSR snapshots (`graph_csr_*`, buffers plus a WBT slot map); dense matrix graphs (`graph_dense_*`, which per its header uses a list of cells and a WBT slot root).
- Sharing: an update copies the path to the changed position and shares every other node with the old version (design README: "the old root and every node not on a changed path remain usable"). Within one family all versions allocate in the one family arena, which is what makes meld constant time within a family (design §0).
- Not verified by me: node counts per family, the exact layout of Brodal-Okasaki nodes, and how the live graph stores inner adjacency sets (Q13 implies a WBT set per vertex inside a WBT map; I did not confirm in source).

## 6. Users and constraints from Project BEES

From `/Volumes/2T/project-bees/development-plan/roadmap.md` and `gap-ledger.md`. I read the rows below, not the whole plan.

- **A1 (Terms and memory):** maps in Erlang term order over `wbt_map`.
- **A3:** ETS as actor-owned tables over `wbt_map`, with documented concurrency differences.
- **D18:** the supervisor position map, a program-wide `wbt_map` from supervisor position to supervisor, generated by `bees_config` and kept current by the runtime.
- **S-16:** a hash map, wanted for O(1) ETS operations; `wbt_map` is the stand-in.
- **S-15:** region release inside a living actor (ROADMAP chunk 4). BEES's substitute for garbage collection is evacuation of `bees_term` regions; the plan marks S-15 as a 1.0 blocker for A1, since without it only short-lived processes run. The A1 row of the BEES roadmap (`roadmap.md`, line ~434) states the gate: "A long-running process's memory stays flat under load." Any redesign must not make a long-lived actor's structure memory grow without bound.
- BEES source so far uses only an inline `List` (verified: a grep of the 62 BEES `.silica` files found only `List[{ id: atom ...` in 12 places and no `wbt_map` or other stdlib structure). I did not examine the details of table contents (keys, values, sizes, update rates) that A1, A3 and D18 will need; that is for BEES's own planning.

## 7. Non-goals, open questions, acceptance

### 7.1 Non-goals / out of scope

- No compiler or stdlib code in this document.
- No new structure families, and no change to the algorithms (WBT, Brodal-Okasaki, skew-binary lists), balance rules or comparator laws; they change only if the ownership model forces it.
- A garbage collector.
- A hash map (BEES S-16) is a separate item.
- Chunk 4's other stages (checker, drops, errors, atomics, bounds) except where they depend on the structure model.

### 7.2 Questions for Lee

1. Which resolution of section 4: (A), (B), (C), (D), or another?
2. How is Q2 (a) resolved against Q13 and Q14: an exception for freeable structures, or a new storage model for all structures?
3. Q13: where does the copy go, and is the copy explicit or implicit in `get`?
4. Q14: the copy's type and relation to `arena(L, S)` and Q16; who makes the copy; destination.
5. Does `arena(L, S)` (Q1) survive, or is it replaced by the new model's handle?
6. Is a structure version linear? If yes, how do generic stdlib modules (Q11) work?
7. Does an update with a still-live old version have any memory-release path, or must a program drop the whole region (A)?
8. Should the §3.14 result reshaping be done in this chunk, or stay unscheduled?
9. Should `copy_to` preserve internal sharing? (Answered for messages 2026-10-23: yes, R4.2; the stand-alone `copy_to` builtin is presumably the same, to confirm.)
10. (D) RESOLVED 2026-10-23 (Lee, option C): a send copies by default, into a fresh owned region that moves to the receiver; an explicit move is available on request.
10a. DECIDED 2026-10-23 (Lee): the explicit move is spelled `move`. The legacy `move` builtin (old actor-migration alias; migration is `migrate_actor`) is being removed from the compiler, so there is no collision.
11. (D) Is the evacuate-on-return rule (copy only nodes inside the popping frame) acceptable, or should a callee allocate in the caller's area? Direction recorded 2026-10-23 (R4.3): destination-passing where the compiler sees the value flow to the return, evacuation otherwise; confirm.
12. (D) Must structures be immutable-only, with a rule against ref cells holding them?
13. (D) Is a state copy at the end of each dispatch acceptable cost, and where does state live (to be checked)?

### 7.3 Acceptance criteria

Matching ROADMAP row 15: a written design replacing the family-arena model, with the Q13 and Q14 open details (copy destination and spelling; type relation to `arena(L, S)` and Q16; who makes the copy; whether Q2 (a) gets an exception) decided by Lee; the stdlib structures rebuilt or adapted under it; trials for each rule in section 2 (R1 to R4, each Q above); the fixed points hold. Chunk 4 stage 2 can then proceed.
