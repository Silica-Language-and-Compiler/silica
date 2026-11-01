# List Implementation Design (silica-compiler)

## 1. Purpose and scope

This document specifies how **immutable, Erlang-style lists** (`List[T, S]`) are implemented in the **Phase 2 self-hosted compiler** (`silica-compiler`): representation, **early desugaring** to regions and buffers, **linear region** ownership with a **bundle** model, **memory space** `S` (aligned with `alloc_region(S)` and `mem(S)`), and the **v1** operation set. It is a **compiler implementation** design; it does not replace the **language** definition in [silica-specification.md](silica-specification.md), but where this doc is more specific (e.g. ownership), implementation follows this document.

**In scope**

- Parser, types, lowering, **SIR** (or intermediate chosen by the project), and **codegen** paths for lists **only** in `silica-compiler`.
- **Trials** under `silica-compiler/trials/list_addition/` (and extensions of that directory).
- Integration with the **memory region** model as described in region tutorials and region-related design notes.

**Out of scope**

- **silica-bootstrap-compiler**: no list implementation work there for this effort.
- **`AArch64/Apple_Silicon/experiments/`**: bootstrap-specific; **no** new list material there.
- **Slices, views, and streams** as separate user-facing types for list-like data in this implementation pass.
- **User-visible** reference counting or explicit `retain`/`release` in the language.
- **Tracing** **GC** or **reference** **counting** **for** **list** **spine** **chunks** (**§9.4**): **reclamation** **follows** **region** **semantics** **only**.

---

## Implementation status (2026-10-16)

The design is implemented for the v1 kernel except `map`, `filter` and `reduce`. Facts that differ from, or refine, the text below:

- **Surface syntax in code.** The space is written with the effect wrapper: `List[int64, mem(normal)]`, `empty[int64, mem(normal)]()`, `length[int64, mem(normal)](xs)`. The shorter `List[int64, normal]` in the examples below is prose shorthand (the tutorials say the same). List values are consumed with the fields `.is_nil`, `.head`, `.tail` in `case`, and `list_at[T, S](xs, i)` (also `list_nth`) reads the i-th element without a `.tail` walk. Compiler-known primitives: `list_nil`, `list_cons` (`prepend`), `list_length`, `list_head`, `list_remove_head`, `list_at`.
- **Representation (all four backends; Apple Silicon reference in `emitter/apple_silicon_mac/terms/prims/prims_list.silica`, runtime in `rt_list.S` per target).** A list value is a 24-byte handle (`length`, `chunk_ptr`, `cursor`); the empty list is 0. A chunk is `[element slots, filled back to front][next chunk][claim]`, so the allocation is `CDATA + 16` bytes, with `CDATA = max(16, elem_slot_bytes)`. Chunks and handles are allocated with `_silica_rt_region_alloc`. The handle is immutable; chunk slots are written once.
- **Copy-on-write prepend.** The claim word records the lowest data offset already handed out; a prepend onto a list whose cursor is not the chunk's frontier copies the live part of the chunk into a fresh chunk, so two prepends onto one list no longer overwrite each other (persistence; AArch64, x86-64 and ESP32-S3 runtimes). This replaces the "mutable chunks" wording of the emitter header.
- **Boxed elements.** Since the uniform boxed record layout, every record field is one word, and list cells of record/tuple/string/list/fn elements hold pointers to a copy made in the region before the prepend; the only inline exceptions are runtime-built records (child-spec lists, `which_children` cells; `element_type_is_runtime_inline_record`).
- **Cursors and the bundle.** There is no separate cursor set: each `List[T, S]` value is its own handle (head cursor), `.tail` allocates a new 24-byte handle, and a name that ends with its scope releases nothing separately. The unbounded cursor set of section 9.1 and the scope-exit cursor drop of 9.7 are realized by handle values and region lifetime, not by bundle metadata.
- **Early desugaring.** List operations lower in SIR to prims (`list_*`) that the emitters expand directly; there is no retained `List` IR node beyond that prim set.
- **Space checking.** The `mem(S)` agreement of 9.8 is enforced by the effect checker (`E3011 ListMemorySpaceMismatch`); allocation of every space comes from the same arena today (see `memory-effects-aarch64-implementation-plan.md` implementation status).
- **Not implemented.** `map`, `filter`, `reduce` (see `Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md`) and SIMD-width chunks (`list_chunk_vector_alignment_todo.md`). The standard collections use fold-style modules in `stdlib/data_structures` instead.
- **Trials.** `trials/list_addition/` now holds 537 `.silica` files (the inventory in section 8 lists the original design trials; later additions include `list_at_*`, the record and tuple element trials and the generated `train_list_*` sets). Tree and trial paths below written as `silica-compiler/...` are `compiler/...` and `trials/...` in the current layout.

---

## 2. Goals (semantic)

| Goal | Description |
|------|-------------|
| **Immutability** | List operations do not mutate existing abstract list values; **prepend** and related operations yield new logical lists while **reusing** shared suffix storage where defined by the representation. |
| **Head-oriented API** | Construction and observation align with **head** operations (as in the language spec); **no** middle/end removal in v1 unless the spec already commits otherwise. |
| **Erlang-like sharing** | Multiple **names** for prefixes over the same storage are **supported** without duplicating the suffix, subject to the **ownership model** in §6. |
| **Vector chunks (day 1)** | Chunks are sized to **vector-processing width** on the target (e.g. 128-bit / 256-bit on AArch64); **pack** multiple elements per chunk when `sizeof(T)` allows **and** alignment rules permit. |
| **Region integration (day 1)** | Lists **desugar** to **allocated buffers** tied to **Silica memory regions**; no “floating” pointers without region authority. |
| **Early desugaring** | The long-lived **primary** representation in the compiler pipeline is **not** a bespoke high-level “list IR” that survives to codegen; lists become **regions + buffers + linkage + metadata** as early as is practical. |
| **Kernel operations (v1)** | **Compiler-known** primitives include at least: **empty**, **prepend**, **remove_head** (or equivalent), **length** (O(1), **memoized**), **map**, **filter**, **reduce**, and **full** **`case`** on lists including **`_`** and **cons**. |
| **Materialized map/filter/reduce** | **No** separate slice/view/stream types in this pass; **map** and **filter** produce **new** `List` materializations; **reduce** is a fold. **Chained** map/filter may allocate **intermediate** lists). |

---

## 3. Surface language (reference)

The **authoritative** surface syntax and typing rules remain in [silica-specification.md](silica-specification.md), including:

- `List[ElementType, Space]` with **Collectable** on the element type (or **`Collectable`** as the element **placeholder** — §8.2.4 silica-spec) and a **memory space** `Space` from the same vocabulary as **`alloc_region(Space)`** (e.g. **`normal`**, **`atomic`**, **`normal_writethrough`** — see [memory_region_types.md](../tutorials_and_howtos/memory_region_types.md)).
- **Element type:** either a **concrete** inline `T` or **`Collectable`** resolved to concrete `T` per value flow from bindings, parameters, returns, or scrutinee types (silica-spec §8.2.4). The compiler does **not** infer element type from literal elements alone without an annotation.
- **Space `S`:** remains explicit in `List[T, S]` for a value flow; the compiler does **not** infer `S` from the enclosing `sequence` effect alone; **`S`** must **agree** with **`sequence proc[mem(S)]`** wherever list storage is **allocated** or **accessed** (§9.8).
- **List literals** and **pattern matching** use the **resolved** `List[ElementType, Space]` in patterns and annotations (same **`Space`** as the scrutinee).

**Uniformity (spec):** [silica-specification.md](silica-specification.md) §4.2.4 requires the **same** list type (after placeholder resolution) across parameters, locals, returns, literals, and patterns for one data flow. **Standard data structures** (graphs, trees, heaps, sets, maps) now use trait-oriented constructor function records for their public construction model; their generated representation records should store concrete **`List[T, S]`** fields once the collection type and constructor record have been checked. The `List[Collectable, S]` placeholder rule remains list/compiler machinery, not the standard-structure constructor strategy.

**Compile-time list data** (literals, static initialization) is handled by **ordinary compiler lowering**, not user-level macros (Silica does not have macros).

### 3.5 Memory space `S` in the list type

- **`S`** is a **type-level** (or otherwise **statically explicit**) **memory space**; **runtime** does **not** infer or dispatch on `S` for **semantics** (no **runtime** **space** inference).
- **`List[T, S]`** **carries** **`S`** across **move** and **return** so **callers** and **callees** keep a **single** **consistent** **story** with **`region(L1, S)`** for the **list’s** **owning** **region**.
- **List primitives** (`empty`, **`prepend`**, **`length`**, …): support **`List[Collectable, S]`** in their declared result/parameter types; resolve to concrete **`T`** from context when the call appears under a typed binding or argument (silica-spec §8.2.4). **Explicit** bracket instantiation at the call site (e.g. **`empty[int64, normal]()`**) remains valid when context resolution is not used. **`S`** is still not inferred from **`sequence proc[mem(S)]`** alone (see §7).

---

## 4. Physical representation (conceptual)

### 4.1 Chunks and buffers

- A **logical list** is an **ordered spine** of **chunks**.
- **All chunks of one spine** live in **one** **Silica memory region** (see §9.2). **Inter-chunk** links are **in-region** (or use handles **scoped** to that region); spines **do not** span **multiple** owning regions.
- Each **chunk** is a **fixed-capacity** buffer aligned to the **vector width** (e.g. 128 bits); **capacity in elements** depends on `T` and **packing** (§4.2).
- Chunks are **linked** (e.g. **next** pointer or handle) so traversal **stops** at the **end** of the chain **for every** `List[T, S]` that reaches that far. **Different** `List[T, S]` “views” are **different entry points** into the **same** linked structure when sharing applies.
- **Within** each **chunk**, **prepend** **fills** **from** **the** **back** **toward** **the** **front** **until** **full**, then **continues** **in** **the** **next** **chunk** (§9.5).

### 4.2 Packed scalars

- When **more than one** element of type `T` fits in a chunk **according to** `sizeof` and **alignment** rules, **pack** them in a **deterministic** order consistent with **§9.5** (exact **slot** **indices** **from** **back** **forward** **per** **chunk** must be **fixed** for vectorized access and codegen).
- **Scalar `T`** includes all primitive **`Collectable`** types in silica-spec §8.2.4, including **`uint8`–`uint64`** as well as signed integers and floats.

### 4.3 Empty list

- An **empty** list has **no** allocated chunk buffer **or** is represented by a **sentinel** empty state **without** a region-backed buffer, consistent with region and trial conventions.

### 4.4 Non-primitive elements

- Where the spec places **region references** into buffers for non-primitive `T`, follow that **indirection** model; **provenance** for pointed-to regions follows existing region rules.

### 4.5 Emitter alignment (current silica-compiler)

Sections **§2** (“**Vector chunks (day 1)**”) and **§4.1** describe chunks as **aligned to vector width on the target** (with **AArch64 examples** such as **128-bit** or **256-bit**), **packing** multiple elements per chunk when **`sizeof`**/**alignment** permit. That wording is **normative for representation goals**—slabs should eventually support **straightforward SIMD** traversal where the ISA allows.

The **living Apple Silicon emitter** (`emitter/apple_silicon_mac/terms/prims/prims_list.silica`) implements a **narrower**, **partial** slice of that intent:

| Concern | In this document | In the emitter today |
|--------|---------------------|----------------------|
| **Chunk data bytes** \(**`CDATA`**\) | Vector width × packing rules (**§4.1**, **§4.2**) | **`CDATA = max(16, elem_slot_bytes)`**, where **`elem_slot_bytes`** is derived from **`T`** only (**`chunk_elem_slot_bytes`** / **`chunk_data_bytes`**). **`16`** matches **Neon’s 128-bit lane bundle** commonly used as a “minimum vector slab,” but **is not derived from ISA / `-mcpu` / feature-matrix selection** (**fixed constant today**). |
| **Full chunk allocation** | **Chunk buffer** + linkage | **`CDATA`** bytes for **filled-back-to-front** slots (**§9.5**) plus **`8`** bytes for **`next`** and **`8`** bytes for the copy-on-write **claim** word; see file header comments in **`prims_list.silica`**. |
| **Codegen** | **§9.5** fixed layout should **admit** eventual **vector loads/stores** | **Scalar** **`LDR`/`STR`** (and width variants); **no** Neon **`LD*`** list fast paths yet. |

So: **documentation** states **SIMD-motivated sizing and packing** as the **target** behavior; **`silica-compiler`** currently uses a **fixed 128-bit-style minimum slab** (**16 bytes**) plus **scalar** helpers. Closing the gap (**256-bit slabs**, ISA-selected **`CDATA`**, **SIMD emits**, allocator **alignment**) is tracked in **[list_chunk_vector_alignment_todo.md](list_chunk_vector_alignment_todo.md)**.

---

## 5. Early desugaring

- **Target shape:** list operations **lower** to a small set of **operations** on **regions** and **buffers**: allocate chunk, write slots, link **next**, update **bundle** cursors (§6), maintain **cached length** where applicable.
- **SIR / middle-end:** **lower** **list** **operations** **to** **regions**/**buffers** **immediately** **in** **all** **paths** (§9.6); **do** **not** **retain** a **persistent** **opaque** **`List`** **node** **across** **middle-end** **passes** **for** **debugging** **or** **alternate** **paths**.

---

## 6. Ownership: linear regions and the “bundle”

### 6.1 Problem

Silica **regions** are **moved** when passed and returned; **at most one** **owning** token for a given allocation **must** be the model the **user** reasons about. **Indices** or **heads** into a buffer are **not** valid without the **accompanying** region **authority**.

### 6.2 Approach: two names, one bundle

**Sharing** (multiple logical list prefixes or **names**) is expressed **inside** **one** **movable aggregate** (the **bundle**):

- The bundle carries **one** **owning** **region** for the **entire** spine (**all** chunks of that list—§9.2) **plus** the **metadata** needed for **multiple** **entry cursors** (heads) **without** duplicating **owning** region tokens at the type level.
- The programmer **names** “views” **through** the **bundle’s API** (or through operations that **return** an **updated** bundle whose API exposes **prior** and **new** heads), **not** as **two** independent **owned** regions to the **same** storage.

### 6.3 Consequences

- **`List[T, S]`** **is** the **bundle** type: **one** **type** **carrying** **region** **authority** **for** **space** **`S`**, **plus** **cursor** **metadata** **(§9.7)**. **No** **separate** **internal** **`ListBundle[T]`** / **`ListContext[T]`** **as** **the** **“real”** **type** **with** **`List[T, S]`** **as** **a** **thin** **wrapper**—**not** **viable** **here**.
- **List** **storage** **reclamation** is **not** via **GC** or **refcount** (see **§9.4**): **only** **memory** **region** **move** **semantics** and **the** **region’s** **lifetime** **/** **deallocation** **rules**. **Chunks** **live** **only** **inside** **that** **region** (§9.2).

### 6.4 Length memoization

- **`length`** is **O(1)** via **memoization** on the **bundle** or **chunk metadata** as appropriate; **immutable** lists do **not** require **invalidation** of cached length for **v1** (no **mutable** length through interior mutation).

---

## 7. Operations (compiler-known primitives)

The following are **v1** goals (exact names match the language spec where it already defines them):

- **Construction / destruction at head:** `empty`, `prepend`, `remove_head` (or spec-equivalent).
- **Observation:** `length`, **pattern matching** with **`[]`**, cons, **`_`** (**`case`** **uses** **only** **the** **current**/**primary** **cursor**—§9.7).
- **Higher-order:** `map`, `filter`, `reduce` **materialized** to `List` / value as specified.

**Typing** and **Collectable** constraints follow the **language spec**.

**Effects and surface shape:** **List** **allocation** (literals, **`empty`**, **`prepend`**, spine **growth**) **must** appear **inside** a **`sequence`** block that **declares** the **`mem(<space>)`** effect (see **§9.3**), and **`<space>`** **must** **equal** the **`S`** in **every** **`List[T, S]`** **value** **touched** in that block (§9.8). **Canonical** shape:

```silica
sequence proc[mem(normal)]
    -- list construction / operations using that region; S in List[T, S] equals mem's space
    xs: List[int64, normal] <- [1, 2, 3]: List[int64, normal];
    result: int64 <- length[int64, normal](xs);
produces
    pure result
end
```

**`<space>`** is a **memory** **space** from the same vocabulary as **`alloc_region(<space>)`** (e.g. **`normal`**, **`normal_writethrough`**, **`atomic`**, **`normal_noncacheable`** — see **`tutorials_and_howtos/memory_region_types.md`**). **That** **same** **`mem(<space>)`** **covers** the **list** **region** and **every** **additional** **buffer** **when** **chunks** **are** **added**. If the **block** **also** **performs** **I/O** (e.g. **`print`**), **declare** **combined** **effects**, e.g. **`sequence proc[mem(normal), device_io]`** (see **`trials/list_addition/list_int64_two_primaries_shared_suffix.silica`**).

**Call sites** for list primitives: prefer **`xs: List[int64, normal] <- empty()`** or **`prepend(x, xs)`** with **`xs`** already typed; optional **`empty[int64, normal]()`** when explicit. **`Collectable`** element placeholders in stdlib list ops resolve from that context. **`S`** is not inferred from lexical `mem` alone (§3.5, §9.8).

**Named** **functions** **may** **declare** **effects** **on** **the** **signature** **when** **the** **API** **surface** **is** **fixed** (e.g. **`with mem(S)`**); **at minimum**, **put** **`sequence proc[mem(<space>)] … produces pure … end`** **inside** **the** **function** **body** **when** **the** **body** **allocates** **or** **reads** **list** **storage** (**`case`** **on** **`List[T, S]`**, **etc.**). **Recursive** **list** **walks** **repeat** **that** **sequence** **per** **call** (see **`list_int64_recursive_sum.silica`**).

---

## 8. Trials and validation

- All **executable** **trials** for **lists** live under **`silica-compiler/trials/list_addition/`**. **Each** **trial** **uses** **`sequence proc[mem(<space>)] … produces pure … end`** (and **`device_io`** **when** **printing**). **Types** **must** **use** **`List[T, S]`** **consistently** **for** **parameters**, **variables**, **literals**, **and** **patterns** **(§4.2.4** **uniform** **list** **types** **in** **silica-specification.md**). **Inventory:**
  - **`list_int64_create_literal_and_empty.silica`** — literals, **`empty`**, **`length`**; **`mem(normal)`**.
  - **`list_int64_mem_effect_sequence.silica`** — minimal **`mem(normal)`** + list + **`length`**.
  - **`list_int64_mem_writethrough.silica`** — **`mem(normal_writethrough)`** (non-**`normal`** **space**).
  - **`list_int64_prepend.silica`**, **`list_int64_remove_head.silica`** — head ops; **`mem(normal)`**.
  - **`list_int64_recursive_sum.silica`** — **recursive** **`sum_list`**; **`case`** **inside** **`sequence proc[mem(normal)]`** **(no** **`proc`** **on** **the** **function)**; **`main`** **also** **`sequence proc[mem(normal)]`** **for** **the** **literal**.
  - **`list_int64_two_primaries_shared_suffix.silica`** — two **`List[int64]`** **values**, **`case`** **on** **each** (**§6**/**§9.7**); **`mem(normal), device_io`** **for** **stdout**.
  - **`list_uint32_prepend_second_chunk.silica`** — nine **`prepend`** steps on **`List[uint32]`** after **`empty`** so **at least two** chunks on the spine are exercised (four **`uint32`** entries pack into the emitter’s **`CDATA = 16`** bytes; aligns with **§4.5**—not §4.1’s hypothetical **256-bit-only** slabs until **list_chunk_vector_alignment_todo.md** closes the gap).
- **Memory-region** trials under **`trials/memory_region_addition/`** (and related) are **prerequisites** or **cross-checks** for buffer writes and region typing. **Each** **`.silica`** **file** **includes** a **header** **comment** **stating** **that** **the** **memory** **space** **`S`** **in** **`sequence proc[mem(S)]`**, **`alloc_region(S)`**, and **`region(L1, S)`** / **`ref`** / **`buf`** **uses** **the** **same** **vocabulary** **as** **`List[T, S]`** (§3.5, §9.8).

---

## 9. Design decisions (resolved)

The following **§9** sections record **agreed** decisions for **list** **implementation** in **silica-compiler**.

### 9.1 Resolved: cursor growth

- **Cardinality over time:** The number of **cursors** in a bundle may grow **without a fixed cap** (unbounded over the lifetime of the bundle).
- **Dropping one cursor:** A **single** cursor may be **dropped** while the **bundle** remains **live** and **other** cursors remain **valid**. Dropping a cursor **does not** by itself **destroy** the bundle or **free** the **region** if other cursors still **reference** storage; it **removes** one **entry point** from the bundle’s **cursor set** (implementation: shrink or tombstone **metadata** as defined by the runtime). **Reclamation** of **storage** **reachable** **only** **from** **dropped** **cursors** **follows** **§9.4** (no **GC** / **refcount**; **region** **move** **only**).

### 9.2 Resolved: one region per spine

- **All** chunks belonging to **one** list **spine** (one **linked** chain of buffers for a **single** logical list’s storage graph) **must** reside in **one** **Silica memory region**.
- **Rationale:** **One** **move** of the **bundle** carries **one** **region** authority; **inter-chunk** pointers never **cross** region boundaries for the **same** spine. **Growth** (new chunk when a buffer fills) **allocates** **inside** that **same** region per the region’s **growth** rules.
- **Non-primitive** elements that **point** at **other** regions (e.g. nested **values**) follow **existing** region rules; only the **list spine’s** **chunk buffers** are constrained **here**.

### 9.3 Resolved: effects for list allocation

- **Declaration:** **List** **allocation** **requires** a **`mem(<space>)`** **effect** on the **`sequence`** **block** (the **memory** **space** matches **region** **policy**, e.g. **`mem(normal)`**, **`mem(normal_writethrough)`**, **`mem(atomic)`**, **`mem(normal_noncacheable)`** — see **`memory_region_types.md`**).
- **Surface** **shape:** **`sequence proc[mem(<space>)]`** … **statements** … **`produces`** **`pure`** **`<value>`** **`end`**. **Combined** **with** **I/O:** **`sequence proc[mem(<space>), device_io]`** when **needed** (see **`list_int64_two_primaries_shared_suffix.silica`**).
- **Reuse:** **That** **same** **`mem(<space>)`** is **reused** **every** time a **new** **buffer** is **added** to **that** **region**—including **each** **additional** **chunk** when the **spine** **grows** inside a **single** **region** (§9.2). **No** **separate** **effect** **binding** per **buffer** **append**; **growth** **stays** under the **same** **`mem`** **declaration** established for **that** **list’s** **region**.

### 9.4 Resolved: runtime strategy under the bundle

- **No** **tracing** **garbage** **collection** and **no** **reference** **counting** for **list** **spine** **storage** (**neither** **in** **the** **language** **nor** **hidden** **in** **the** **list** **runtime** **for** **chunks**).
- **Ownership** **and** **reclamation** **are** **memory** **region** **semantics** **only:** **the** **bundle** **moves** **with** **its** **region** **authority**; **all** **chunks** **are** **allocated** **inside** **that** **region** (§9.2). **Lifetime** **ends** when **the** **region** **is** **dropped** **or** **moved** **out** **of** **scope** **per** **Silica’s** **linear** **region** **rules**—**not** **per** **chunk** **refcount** **or** **GC**.
- **Implication:** **Erlang-like** **structural** **sharing** **must** **be** **expressed** **without** **two** **independent** **owning** **region** **tokens** **to** **the** **same** **bytes**—**i.e.** **through** **the** **bundle** **model** (§6.2) **and** **cursor** **metadata** **within** **one** **moved** **value**, **not** **through** **shared** **heap** **cells** **with** **RC**/**GC**.

### 9.5 Resolved: chunk fill direction

- **First** **element** **in** **a** **chunk** **occupies** **the** **back** **of** **that** **chunk’s** **buffer** (**last** **slot** **in** **the** **chunk’s** **element** **ordering** **for** **prepend** **growth**).
- **Further** **prepends** **fill** **the** **chunk** **from** **that** **back** **toward** **the** **front** **until** **the** **chunk** **is** **full**.
- When **no** **room** **remains** **in** **the** **current** **chunk**, **prepend** **continues** **in** **the** **next** **chunk** **in** **the** **spine** (**linked** **per** §9.2). **Vectorized** **loads**/**stores** **must** **agree** **with** **this** **fixed** **layout** **per** **chunk** **width** **and** **`T`** **packing** (§4.2).

### 9.6 Resolved: SIR staging

- **Lower** **immediately** **in** **all** **paths:** **list** **values** **do** **not** **use** a **retained** **intermediate** **`List`** **representation** **in** **SIR** (or **equivalent**) **across** **passes** **for** **debugging**, **optional** **pipelines**, or **backend** **branching**. **Every** **path** **that** **constructs** **or** **consumes** **a** **list** **lowers** **promptly** **to** **the** **region** + **buffer** + **bundle** **model** (§5). **Transient** **scratch** **during** **a** **single** **lowering** **step** is **allowed**; **no** **persistent** **staging** **layer**.

### 9.7 Resolved: `List[T, S]` surface and `case` / cursors

- **`List[T, S]`** **is** **not** **a** **thin** **wrapper** **around** **another** **named** **bundle** **type:** **`List[T, S]`** **is** **the** **concrete** **type** **denoting** **region** **(in** **space** **`S`**) **+** **cursor** **set** **+** **associated** **metadata** **for** **list** **storage** **(§6)**. **No** **separate** **user-facing** `ListBundle[T]` / `ListContext[T]` **as** **the** **authoritative** **implementation** **type**.
- **`case`** **on** **a** **`List[T, S]`** **always** **matches** **against** **the** **current**/**primary** **list** **using** **its** **designated** **cursor** **only**; **patterns** **do** **not** **take** **a** **cursor** **parameter**. **Pattern** **types** **use** **the** **same** **`List[T, S]`** **as** **the** **scrutinee**.
- **Other** **cursors** (**secondary** **heads**, **historical** **prefixes**, **etc.**) **are** **held** **in** **ordinary** **variables** **when** **needed**; **when** **a** **variable** **binding** **ends** **(scope** **exit**), **that** **cursor** **is** **removed** **from** **the** **bundle** **metadata** **together** **with** **its** **head** **reference** **into** **the** **region** **(same** **discipline** **as** **explicit** **cursor** **drop**—§9.1).

### 9.8 Resolved: effect checker alignment (explicit `S`, moves, returns)

- **Static** **rule:** **every** **`sequence proc[mem(S)]`** **block** **that** **allocates**, **grows**, **or** **pattern-matches** **a** **list** **must** **use** **the** **same** **`S`** **as** **the** **`List[T, S]`** **types** **of** **all** **list** **values** **accessed** **in** **that** **block**. **No** **inferring** **`S`** **only** **from** **the** **block** **effect** **while** **the** **value** **type** **is** **silent** **—** **`S`** **is** **part** **of** **`List[T, S]`** **(§3.5)**.
- **Moves** **and** **returns:** **`S`** **is** **preserved** **in** **the** **type** **`List[T, S]`**; **callees** **cannot** **honestly** **declare** **`mem(S′)`** **for** **list** **work** **unless** **`S′`** **=** **`S`** **(unless** **the** **language** **defines** **a** **sound** **widening** **—** **none** **is** **assumed** **here** **for** **distinct** **spaces).
- **Region** **trials** **and** **list** **trials** **share** **one** **memory-space** **vocabulary**; **`trials/memory_region_addition/`** **headers** **cross-reference** **this** **document** **for** **`List[T, S]`**.

---

## 10. References

- [silica-specification.md](silica-specification.md) — language definition for lists, literals, patterns.
- [silica-compiler-code-organization.md](silica-compiler-code-organization.md) — parser/codegen file names for lists, patterns, types.
- `silica-compiler/tutorials_and_howtos/memory_region_types.md` — region spaces and allocation examples.
- `silica-compiler/trials/list_addition/` — executable trials.
- `silica-compiler/tutorials_and_howtos/list_memory_space_and_effects.md` — **lists**, **`mem(S)`**, and **`List[T, S]`** alignment with **regions**.
- [list_chunk_vector_alignment_todo.md](list_chunk_vector_alignment_todo.md) — **TODO:** chunk SIMD width, allocator alignment, and vectorized emits vs §4.5.

---

## Document history

| Version | Summary |
|---------|---------|
| 1.0 | Initial design: desugaring, chunks, bundle ownership, v1 kernel, out-of-scope items, open questions. |
| 1.1 | Resolved §9.2 cursor growth: unbounded cursors; single cursor droppable while bundle and others live. |
| 1.2 | Resolved one region per spine: all chunks of a list spine live in one Silica memory region (§9.2). |
| 1.3 | Resolved effects §9.3: `mem` type effect for list allocation; same `mem` reused for each new buffer in the region. |
| 1.4 | Resolved §9.4 runtime: no GC, no refcount; region move only; chunks live in the region. |
| 1.5 | Resolved §9.5 chunk fill: first element at back of chunk; prepend fills toward front until full; then next chunk. |
| 1.6 | Resolved §9.6 SIR: lower immediately in all paths; no retained staging List IR. |
| 1.7 | Resolved §9.7: `List[T]` is the bundle (no thin wrapper); `case` uses primary cursor; other cursors in variables, removed at scope end. |
| 1.8 | §8 trials: list_addition files aligned with design (headers, mem sequence, two primaries). |
| 1.9 | §7/§8/§9.3: canonical `sequence proc[mem(<space>)]` shape; trial inventory + writethrough example; spec cross-ref. |
| 1.10 | §8: `list_uint32_prepend_second_chunk.silica` (nine prepends; ≥2 chunk buffers for 128/256-bit layouts). |
| 1.11 | §8: `list_int64_recursive_sum.silica` (recursive function over list). |
| 1.12 | §7/§8: effects only on `sequence` (not function return types); `list_int64_recursive_sum` uses inner `sequence proc[mem(normal)]`. |
| 1.13 | §3.5 `List[T, S]` and explicit memory space; §9.8 effect checker alignment; §7/§9.7 updated; `memory_region_addition` trial headers cross-reference; optional `with mem(S)` on functions. |
| 1.14 | §3/§8: uniform list types—parameters, variables, literals, patterns must match; cross-ref silica-specification §4.2.4; trials use consistent `List[T, S]`. |
| 1.15 | §4.5 emitter alignment vs §2/§4.1 vector-chunk wording; §8 trial wording for multi-chunk `uint32`; cross-ref **list_chunk_vector_alignment_todo.md**. |
| 1.16 | Implementation status (2026-10-16): `mem(S)` syntax in code, handle and chunk layout with claim word, copy-on-write prepend, boxed elements, map/filter/reduce not implemented. |
