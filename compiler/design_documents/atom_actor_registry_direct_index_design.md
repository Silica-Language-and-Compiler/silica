# Atom-keyed actor registry — direct indexing design

## Implementation status (2026-10-16)

The design is implemented in the runtimes, with these specifics:

- **Table sizing.** The table is not the 240-slot `buf` plus overflow list of the former `runtime_modules/pid_registry_actor.silica` / `pid_register_runtime.silica` (removed 2026-10-16). Each registry is a calloc block sized by `silica_registry_slots`, which `emitter_core.silica` emits into `__silica_runtime.sams` as the build's atom count: occupancy words `[0, N)` then actor-identity words `[N, 2N)`. Atoms are fixed when a program is built (specification §4.1.7), so the table is allocated once and never grows or overflows; the growth path of §4 and the overflow list are unused. Reads are one bounds check and two indexed loads (acquire load of the occupancy word, then the slot).
- **Atom numbering (§2).** One merged atom table per application (a multi-unit build merges its units' tables, `build_atom_table_executable`); see [APPLICATION_IS_ONE_COMPILATION_UNIT.md](APPLICATION_IS_ONE_COMPILATION_UNIT.md). Ids are dense `0 … N-1` with a fixed pre-seeded prefix.
- **Three tables** (ordinary, dangerous, device), each in its own registry actor; see [pid_registry_process_global_actor_gate.md](pid_registry_process_global_actor_gate.md).
- **Slot values** are actor identities (specification §15.1.4), not raw pointers; liveness is checked against the identity table, and the exit path clears the name.
- **ESP32-S3.** Same layout; the slot count is the same `silica_registry_slots` word, which also distinguishes an atom from an ACB address in the keyed forms. Hand-written asm board apps link a weak default of zero slots.

## 1. Purpose

Silica currently has no built-in hash map type. Recursive user-defined tree shapes for associative lookup are awkward or forbidden under structural typing. At the same time, process registries keyed by **`atom`** and storing runtime references such as **`actor_ref`** and **`supervisor_ref`** need expected **O(1)** lookup—not **O(n)** scans over **`List`**.

This document specifies a **representation and protocol** based on Silica's **atom model**: atoms are backed by **dense integer ids** in a **single intern table per process image** (see §2). The **`id`** range is **`0 … N−1`** (**contiguous** for **`N`** distinct interned literals in that image), optionally after a fixed **reserved prefix** consumed by ABI/runtime. **Density**—not the order in which the compiler/linker discovers or reads literals—is what permits a **simple direct index** into **`slots`** (no hashing, no tree, no chunk-spine traversal for lookup). Assignment order vs source text order is explicitly **unspecified**: only **`(lexeme ↔ id)`** stability and **`0…N−1`** compactness matter here.

**Distinct from runtime refs:** only **`atom_id`** occupies **`0 … N−1`** in registry indexing. **`actor_ref`** and **`supervisor_ref`** remain opaque handles (e.g. pointers); slot values are **not** dense small integers unless the runtime chooses that internally.

**Scope**

- Naming: “registry”, “ETS-like slot table”, **atom → runtime ref**.
- Targets user code (`runtime_modules/`), registered ordinary actors from `spawn_registered`, registered supervisors from `spawn_registered_supervisor`, and optionally future compiler/runtime helpers.

**Non-goals**

- General **`Map[K,V]`** in the surface language (this remains a specialised pattern keyed by **`atom`** only).
- String-based hashing of atom spellings at lookup time (**not needed** when the **`atom`** value already denotes an **`int64`**‑class identifier).

Normative Silica semantics for **`atom`**, **`actor_ref`**, **`supervisor_ref`**, and regions remain in [silica-specification.md](./silica-specification.md).

---

## 2. Preconditions (atom numbering)

Assume the compiler/runtime upholds:

1. **Globally coherent intern table (link-time / process-wide).** Across all translation units linked into **one process image**, there is exactly one logical atom namespace: **each distinct literal atom spelling (lexeme)** maps to **exactly one numeric id**, and separately compiled objects **cannot** disagree on **`spelling ↔ id`** after link. Establishing this may use **linker merging**, **whole-program or thin-LTO‑style pipelines**, **unified runtime startup interning**, or other equivalent means; per-object tables that are incompatible at link/load time **violate** this precondition.
2. **Dense ids (normative for this design):** **`id ∈ { 0 … N−1 }`** for **`N`** atoms in that process image table, **contiguous**, **immutable** once assigned for the lifetime of that table (atoms are **not** garbage‑collected in the Erlang sense). **Reserved id ranges** (e.g. platform or runtime stubs) may occupy a fixed prefix; remaining literals fill **contiguous** ids with **no gaps** within **`0 … N−1`**. Which literal gets which id **except** reserved slots is **toolchain-defined** and **must not** be inferred from source **lexical read order**.
3. **`atom`** values compared or passed at runtime carry that **`id`** at the **`atom`** abstraction (implementation elsewhere; surfaced as **`atom`** in types).

If any future change introduced **reuse of ids**, **holes** without bound across the live table contract, incompatible ids across linked units, or non-numeric **`atom`** comparison, §3–§4 would need hashing or search instead—out of scope for this design while the precondition holds.

---

## 3. Core idea: parallel slot table (`actor_ref`)

Allocate a **single contiguous indexed store** keyed by **`atom_id`** (`int64`, non-negative):

- **`slots[i]`** holds the **`actor_ref`** registered under atom id **`i`**, **`0 ≤ i ≤ max_id_seen`**.

**Slots**

Use a distinguished **empty sentinel** **`actor_ref` value meaning “unset” only if Silica distinguishes it**; otherwise reserve:

- **`valid: bool`** beside **`actor_ref`**, **or**
- **`(atom, actor_ref)`** invariant where **`atom`** repeats the key row (redundant check), **or**
- Separate **bitmap/wordset** parallel to **`slots`**.

Prefer one row shape the type system can express cleanly, e.g. **`{ occupied: bool, pid: actor_ref }`** packed in **`buf`**, **`ref`**, or **`region`** per §4.

---

## 4. Storage and lifetime (regions)

Bindings must obey Silica **`mem(Space)`**: the slot table lives in a region created under the same **`S`** as the registry **`sequence`** (see [list_memory_space_and_effects.md](../tutorials_and_howtos/list_memory_space_and_effects.md) patterns).

Suggested shapes:

| Shape | Resize | Lookup |
|-------|--------|--------|
| **`buf(R, S, Cell, Capacity)`** (if grammar supports fixed capacity) | Realloc/migrate explicitly | **`load buf[id]`** after bounds check |
| **`ref`** to heap bump under **`region(R, S)`** | Grow by **allocate larger + copy + swap handle** rare path | Indexed load after bounds |
| Allocator helper (runtime C stub) exposing indexed buffer | Matches existing **`_silica_rt_region_alloc`**‑style heaps | Emitter load/store at **`base + id * stride`** |

**Growth**

Maintain **`capacity`** and **`high_water`** (largest **`atom_id`** ever written + 1, or **`N`** atoms from compiler static count when available):

- **`atom_id ≥ capacity`** → grow table (**double** until **`capacity > atom_id`**), copy old slots, initialise new tails to empty.
- **Amortised O(1)** insert if the **maximum assigned `atom_id`** grows monotonically (so growth only runs when **`id`** exceeds capacity) and growth factor is **`> 1`**.

Compile-time‑known maximum atom count (if the toolchain reports it): **allocate once** → no growth path during process lifetime.

---

## 5. Operations

### 5.1 Register / update

Given **`key: atom`**, **`id`** its integer backing, **`v: actor_ref`**:

```
if id >= capacity → grow_slots(id + 1);
slots[id] ← v (mark occupied per §3);
maybe update high_water;
```

Precondition **“no overwrite” vs “allow replace”**: policy owned by **`pid_registry`** message handler.

### 5.2 Lookup

```
if id >= capacity ∨ !occupied[id] → not_found convention;
else return slots[id];
```

**Single indexed access** ⇒ **O(1)** worst-case time per lookup after **`slots`** resides in **`cache`/RAM** (**no hashing**).

### 5.3 Delete

Clear **`occupied`**, optionally zero **`pid`**. Do not call **`remove_actor`** implicitly here unless product policy requires it (**remains higher-level**).

### 5.4 Unregister semantics

Deleting a registration entry does **not** shrink **`atom`** ids; **`high_water`** and table capacity unchanged unless a separate compaction phase is justified (normally **not**: ids are immortal).

---

## 6. Contrast with other approaches

| Approach | Complexity | Fits Silica today? |
|-----------|-------------|---------------------|
| **`List`** scan | **O(n)** | Yes, assoc-list overflow (same shape as the PID registry private overflow in the removed `pid_registry_actor` module) |
| **BST / tree** recursive type | **`O(log n)`** nominal | Structural typing friction; user trees painful |
| **Hash table (arbitrary keys)** | **`O(1)`** expectation | No language **`Map`**; hand-built open addressing works but unnecessary when **`atom_id`** is dense **`0…N`** |
| **Direct index (**this doc**)** | **`O(1)`** | Yes, **minimal code**, **minimal metadata** |

---

## 7. Integration points

- Former **`pid_registry_actor`** module (removed 2026-10-16; the live behaviour is the runtime assembly `silica_rt_pid_registry_beh`): swap internal **`List`** for **indexed buffer + `high_water` + grow path**; **`call`** handlers branch on **`atom → id`** (**`call`** payloads carry **`atom`**; **`==`** / id comparison aligns with **`atom`** lowering). Safe only if callers and registry agree on the **same process-wide atom id** encoding (§2).
- **Compiler / linker / loader**: expose or consume a **unified atom table artifact** so every object in the image agrees on **`spelling ↔ id`**; codegen that today builds a **per-TU atom table during emission** must be superseded by, or fused with, whichever pass produces the **process-wide** table (or relocate final id assignment to link/runtime per §2).
- **Compiler**: if **`atoms_count`/`max_atom_id`** is surfaced **for the merged image**, allocate registry capacity **once** and skip the **`grow`** path in steady state.
- **`remove_actor`/GC**: orthogonal—registry row eviction does **not** recycle **`atom`** numbers.

---

## 8. Document history

| Version | Summary |
|---------|---------|
| 1.0 | Initial design: **`atom`** sequential **`id`** → **`O(1)`** **`actor_ref`** slot table, region-backed growth option, contrast with **`List`**, tree, generic map. |
| 1.1 | Normative **link-time / process-wide** intern table (§2); clarify **lexeme vs occurrence** and **`actor_ref`** vs dense **`atom_id`**; toolchain integration bullets (§7). |
| 1.2 | **Density** over **read/source order**: normative precondition is **contiguous `0…N−1`** and stable **`lexeme ↔ id`**; assignment order vs source text **unspecified** (§1, §2). |
